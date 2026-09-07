package economy;

use strict;
use warnings;
no warnings 'redefine';

use AI;
use Commands;
use Globals qw($char $field $net $messageSender %config $buyershopstarted $shopstarted %items_control %incomingDeal %outgoingDeal %currentDeal $playersList);
use Log qw(message warning);
use Misc qw(sendMessage);
use Network;
use Plugins;
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);
use lib dirname(__FILE__) . '/lib';
use Economy::Classifier;
use Economy::Trade;

my $catalog = {};
my %classification_cache;
sub load_item_catalog {
    $catalog = {};
    %classification_cache = ();
    my $path = dirname(__FILE__) . '/item_catalog.json';
    eval {
        open my $fh, '<', $path or die "$path: $!";
        $catalog = decode_json(do { local $/; <$fh> });
        die 'catalog must be an object' unless ref($catalog) eq 'HASH';
        1;
    } or do { $catalog = {}; warning "[ECO][ERROR] catalog unavailable: $@\n"; };
}

# Only autoGear's completed evaluation triggers this read-only observer.
# No inventory mutation, Trade, NPC sell or price calculation occurs here.
sub classify_inventory {
    return unless _in_game();
    return if defined $config{economy_classify_enabled} && !$config{economy_classify_enabled};
    my $classifier = Economy::Classifier->new(catalog => $catalog, npc_rules => \%items_control);
    my %seen;
    for my $item (@{$char->inventory->getItems}) {
        my $result = $classifier->classify_item($item, gear_ready => 1);
        my $key = join(':', $char->{charID} // '', $item->{binID} // '', $item->{nameID});
        my $signature = join(':', $result->{decision}, $result->{reason}, $item->{amount} // 0);
        $seen{$key} = $signature;
        next if ($classification_cache{$key} // '') eq $signature;
        message sprintf("[ECO][CLASSIFY] nameID=%s binID=%s amount=%s -> %s reason=%s (read_only)\n",
            $item->{nameID}, $item->{binID} // '?', $item->{amount} // 0,
            $result->{decision}, $result->{reason}), 'info';
    }
    %classification_cache = %seen;
}


our $NAME = 'economy';
our $VERSION = '1.0.0';

############################################################################
# Economy V1 —— 自动收购（收购店 / buying store）状态机。
#
# OpenKore 原生只提供 buyerShopAuto_open 的“空闲即开一次、一直开着”的简单行为，
# 没有“zeny 见底就关店、回血后重开”的闭环。本插件把收购店当成一个受控状态机：
#
#   [IDLE] --(zeny>=reserve && idle && in lockMap && has license)--> [OPENING]
#   [OPENING] --(server confirms 0x0813)--> [OPEN]  (buyershopstarted=1)
#   [OPEN]   --(0x09E6 update: 每笔收购)--> 记录购买、累计花费
#   [OPEN]   --(zeny<reserve)--> [CLOSING]  (closeBuyerShop)
#   [CLOSING]--(buyer_shop_closed)--> [IDLE]
#
# 配置（config.txt）：
#   economy_buy_store_enabled 1    # 总开关；置 0 关闭本插件
#   economy_buy_store_reserve 2000 # zeny 低于该值自动关店，避免收购店破产
#
# 命令：
#   economy status  查看状态机
#   economy open    立即尝试开店（跳过冷却）
#   economy close   立即关店
#   economy reset   重置会话统计
############################################################################

Plugins::register($NAME, 'Economy V1 auto-buy (收购店) state machine', \&on_unload, \&on_unload);

my $commands = Commands::register(
	['economy', 'economy state machine control', \&command_handler],
);

my $hooks = Plugins::addHooks(
	# AI_pre/manual fires on every AI tick in BOTH manual and auto modes,
	# whereas AI_pre only fires in auto mode. The economy state machine is
	# non-combat and must run for a city-bound merchant regardless of AI mode.
	['AI_pre/manual',              \&on_ai_pre],
	['packet/buying_store_update', \&on_buying_store_update],
	['buyer_shop_closed',          \&on_buyer_shop_closed],
	['autoGear_evaluation_complete', \&classify_inventory],
	['postloadfiles', \&on_postloadfiles],
	['error_deal', \&on_trade_request_error],
	# Sprint 8：普通 Trade 自动收购状态机（seller/buyer）。
	['packet_privMsg', \&on_trade_pm],
	['incoming_deal', \&on_trade_incoming],
	['engaged_deal', \&on_trade_engaged],
	['finalized_deal', \&on_trade_finalized],
	['complete_deal', \&on_trade_complete],
	['cancelled_deal', \&on_trade_cancelled],
	['error_deal', \&on_trade_error],
);

my %state = (
	opened_at        => 0,
	closed_at        => 0,
	last_open_try    => 0,
	last_check       => 0,
	open_fail_streak => 0,
	purchases        => 0,
	spent_zeny       => 0,
	last_close_reason=> '',
);

my $CHECK_SECONDS        = 3;
my $OPEN_RETRY_SECONDS   = 10;
my $OPEN_FAIL_MAX_BACKOFF= 120;

sub econ_log   { message "[ECONOMY] $_[0]\n", ($_[1] || 'info'); }
sub econ_warn  { warning "[ECONOMY] $_[0]\n"; }

sub _enabled {
	my $v = $config{economy_buy_store_enabled};
	return 0 unless defined $v;
	return $v =~ /^(1|yes|true|on)$/i ? 1 : 0;
}

sub _reserve {
	my $v = $config{economy_buy_store_reserve};
	return 0 unless defined $v && $v =~ /^\d+$/;
	return 0 + $v;
}

sub _in_game {
	return $net && $net->getState() == Network::IN_GAME && $char && $field;
}

sub _has_buying_store_skill {
	return $char && (($char->{skills}{ALL_BUYING_STORE}{lv} || 0) > 0);
}

sub _has_license {
	return 0 unless $char && $char->inventory;
	return 1 if $char->inventory->getByNameID(6377);   # Bulk Buyer Shop License (skill path)
	return 1 if $char->inventory->getByNameID(12548);  # Black Market Bulk Buyer Shop License (item path)
	return 0;
}

sub on_ai_pre {
	# Sprint 8 普通 Trade 状态机独立于收购店运行，先 tick（自带 1s 节流）。
	on_trade_tick();

	return unless _enabled();
	return unless _in_game();
	my $now = time;
	return if $now - $state{last_check} < $CHECK_SECONDS;
	$state{last_check} = $now;

	my $zeny    = 0 + ($char->{zeny} || 0);
	my $reserve = _reserve();

	if ($buyershopstarted) {
		if ($zeny < $reserve) {
			main::closeBuyerShop();
			$state{closed_at} = $now;
			$state{last_close_reason} = sprintf('zeny_below_reserve zeny=%d reserve=%d', $zeny, $reserve);
			econ_warn("[STATE] close buying store: $state{last_close_reason}");
		}
		return;
	}

	# Not open yet. Only open when: standing, AI idle, on lockMap, zeny above
	# reserve, not already vending, and we actually have the skill/license.
	return if $char->{sitting};
	return unless AI::isIdle();
	return unless $field->baseName eq ($config{lockMap} || '');
	return if $shopstarted;                       # don't open 收购店 while vending
	return unless $zeny >= $reserve;
	return unless _has_buying_store_skill() || _has_license();

	# Exponential backoff after failed opens, so a missing license/item does
	# not spam makeBuyerShop() (and does not burn licenses) every tick.
	my $backoff = $OPEN_RETRY_SECONDS * (1 << $state{open_fail_streak});
	$backoff = $OPEN_FAIL_MAX_BACKOFF if $backoff > $OPEN_FAIL_MAX_BACKOFF;
	return if $now - $state{last_open_try} < $backoff;
	$state{last_open_try} = $now;

	main::openBuyerShop();

	if ($buyershopstarted) {
		$state{opened_at} = $now;
		$state{open_fail_streak} = 0;
		econ_log(sprintf('[STATE] open buying store requested zeny=%d reserve=%d', $zeny, $reserve), 'success');
	} else {
		$state{open_fail_streak}++;
		econ_warn(sprintf('[STATE] open buying store did not start (streak=%d); check buyer_shop.txt / license / inventory', $state{open_fail_streak}));
	}
}

# 0x09E6 (ZC_UPDATE_ITEM_FROM_BUYING_STORE2) —— 每笔收购成交时服务器发给店主。
sub on_buying_store_update {
	my (undef, $args) = @_;
	$state{purchases}++;
	my $zeny  = 0 + ($args->{zeny}  || 0);
	my $count = 0 + ($args->{count} || 0);
	$state{spent_zeny} += $zeny;
	econ_log(sprintf('[BUY] purchase itemID=%s count=%s cost=%sz (session purchases=%d spent=%dz)',
		$args->{itemID} // '?', $count, $zeny, $state{purchases}, $state{spent_zeny}));
}

# Receive::deal_begin clears only outgoingDeal after a rejected acceptance.
# Clear the stale incoming request too, but never touch an engaged transaction.
sub on_trade_request_error {
    my (undef, $args) = @_;
    return if %currentDeal;
    return unless defined $args->{type} && $args->{type} =~ /^(?:0|1|2|4|5)$/;
    %incomingDeal = ();
    %outgoingDeal = ();
    econ_log("[TRADE] request rejected type=$args->{type}; pending requests cleared");
}

sub on_buyer_shop_closed {
	$state{closed_at} = time;
	econ_log('[STATE] buyer shop closed');
}

############################################################################
# Sprint 8 —— 普通 Trade 自动收购状态机（seller / buyer）。
#
# 用 Economy::Trade（纯状态机）驱动真实 Trade 协议：
#   seller: SELL_REQUEST <nonce> <itemID> → READY → 发起 Trade → 放卡 → 核对报价 → 锁定 → 确认
#   buyer : 校验白名单/nonce → READY → 接单 → 检测卡片 → 放 zeny → 锁定 → 确认
#
# 配置（config.txt）：
#   economy_trade_enabled 1           # 总开关
#   economy_trade_role seller         # seller | buyer
#   economy_trade_item 4023           # 交易物品 nameID
#   economy_trade_price 10000         # 固定价格（z）
#   economy_trade_merchant Cartwright # seller 用：商人名
#   economy_trade_sellers Penny       # buyer 用：卖家白名单（逗号分隔）
#   economy_trade_timeout 30          # 状态 watchdog 秒
#   economy_trade_cooldown 15         # done/error 后重试冷却秒
############################################################################

my $trade;               # Economy::Trade 实例
my $trade_last_tick = 0;
my $TRADE_TICK_SECONDS = 1;

sub _trade_enabled {
	my $v = $config{economy_trade_enabled};
	return 0 unless defined $v;
	return $v =~ /^(1|yes|true|on)$/i ? 1 : 0;
}

sub _trade_role {
	my $r = $config{economy_trade_role} || '';
	return $r eq 'seller' || $r eq 'buyer' ? $r : '';
}

sub _trade_num {
	my ($key) = @_;
	my $v = $config{$key};
	return 0 unless defined $v && $v =~ /^\d+$/;
	return 0 + $v;
}

sub _trade_sellers {
	my %s;
	for my $n (split /,/, $config{economy_trade_sellers} || '') {
		$n =~ s/^\s+|\s+$//g;
		$s{$n} = 1 if $n ne '';
	}
	return \%s;
}

sub _build_trade {
	$trade = undef;
	return unless _trade_enabled();
	my $role = _trade_role();
	return unless $role;
	my %args = (
		role => $role,
		item_id => _trade_num('economy_trade_item'),
		price => _trade_num('economy_trade_price'),
		timeout => _trade_num('economy_trade_timeout') || 30,
		cooldown => _trade_num('economy_trade_cooldown') || 15,
	);
	if ($role eq 'seller') {
		$args{merchant} = $config{economy_trade_merchant} || '';
	} else {
		$args{sellers} = _trade_sellers();
	}
	$trade = Economy::Trade->new(%args);
	econ_log(sprintf('[TRADE] initialized role=%s itemID=%s price=%sz merchant=%s sellers=%s',
		$role, $args{item_id}, $args{price},
		($args{merchant} || '-'), (join ',', sort keys %{ $args{sellers} || {} }) || '-'));
}

# 启动时插件先于 config.txt 加载，故在 postloadfiles（config 已就绪）再构建一次。
sub on_postloadfiles {
	load_item_catalog();
	_build_trade();
}

sub _feed_trade {
	my ($method, @args) = @_;
	return unless $trade;
	_execute_trade_actions($trade->$method(@args));
}

sub _execute_trade_actions {
	my ($actions) = @_;
	return unless $actions;
	for my $a (@$actions) {
		my $type = $a->{type};
		if ($type eq 'log') {
			econ_log($a->{msg});
		} elsif ($type eq 'send_pm') {
			sendMessage($messageSender, 'pm', $a->{msg}, $a->{to});
		} elsif ($type eq 'accept_deal') {
			$messageSender->sendDealReply(3);
		} elsif ($type eq 'reject_deal') {
			$messageSender->sendDealReply(4);
		} elsif ($type eq 'initiate_deal') {
			my ($partner) = grep { $_->name eq $a->{name} } @$playersList;
			if ($partner) {
				main::deal($partner);
			} else {
				econ_warn(sprintf('[TRADE] initiate_deal: %s not nearby', $a->{name}));
			}
		} elsif ($type eq 'add_item') {
			my $item = $char->inventory->getByNameID($a->{nameID});
			if ($item) {
				main::dealAddItem($item, $a->{amount});
			} else {
				econ_warn(sprintf('[TRADE] add_item: itemID=%s not in inventory', $a->{nameID}));
			}
		} elsif ($type eq 'add_zeny') {
			$currentDeal{you_zeny} = $a->{amount};
		} elsif ($type eq 'finalize') {
			$messageSender->sendDealAddItem(pack('v', 0), $currentDeal{you_zeny} || 0);
			$messageSender->sendDealFinalize();
		} elsif ($type eq 'commit') {
			$messageSender->sendDealTrade();
		}
	}
}

sub on_trade_pm {
	my (undef, $args) = @_;
	_feed_trade('on_pm', $args->{privMsgUser}, $args->{privMsg});
}

sub on_trade_incoming {
	my (undef, $args) = @_;
	_feed_trade('on_incoming_deal', $args->{name});
}

sub on_trade_engaged {
	my (undef, $args) = @_;
	_feed_trade('on_engaged', $args->{name});
}

sub on_trade_finalized {
	_feed_trade('on_other_finalized');
}

sub on_trade_complete {
	_feed_trade('on_complete');
}

sub on_trade_cancelled {
	_feed_trade('on_cancelled');
}

sub on_trade_error {
	my (undef, $args) = @_;
	_feed_trade('on_error', $args->{type});
}

sub on_trade_tick {
	return unless $trade && _in_game();
	my $now = time;
	return if $now - $trade_last_tick < $TRADE_TICK_SECONDS;
	$trade_last_tick = $now;

	my %ctx = ( now => $now, other_finalized => $currentDeal{other_finalize} ? 1 : 0 );
	if (_trade_role() eq 'seller') {
		my $item = $char->inventory->getByNameID(_trade_num('economy_trade_item'));
		$ctx{has_card} = $item ? 1 : 0;
		$ctx{other_zeny} = $currentDeal{other_zeny} || 0;
	} else {
		$ctx{other_items} = \%{ $currentDeal{other} || {} };
	}
	_feed_trade('tick', %ctx);
}

sub _print_trade_status {
	return econ_log('[TRADE] disabled') unless $trade;
	econ_log(sprintf('[TRADE] role=%s state=%s itemID=%s price=%sz counterpart=%s nonce=%s',
		_trade_role(), $trade->state(), _trade_num('economy_trade_item'), _trade_num('economy_trade_price'),
		($trade->counterpart || '-'), ($trade->nonce || '-')));
}

sub _print_status {
	econ_log(sprintf(
		'[STATUS] enabled=%s buying_store_open=%s vending_open=%s zeny=%d reserve=%d skill=%s license=%s purchases=%d spent=%dz open_fail_streak=%d last_close_reason=%s',
		_enabled() ? 'yes' : 'no',
		$buyershopstarted ? 'yes' : 'no',
		$shopstarted ? 'yes' : 'no',
		0 + ($char->{zeny} || 0), _reserve(),
		_has_buying_store_skill() ? 'yes' : 'no',
		_has_license() ? 'yes' : 'no',
		$state{purchases}, $state{spent_zeny}, $state{open_fail_streak},
		$state{last_close_reason} || 'none',
	));
}

sub command_handler {
	my (undef, $args) = @_;
	$args = '' unless defined $args;
	$args =~ s/^\s+|\s+$//g;

	if ($args eq 'classify') {
		%classification_cache = ();
		if (defined &autoGear::request_check && $config{autoGear}) {
			autoGear::request_check();
			econ_log('[CLASSIFY] queued until autoGear completes a safe evaluation');
		} else {
			econ_warn('[CLASSIFY] deferred: autoGear is unavailable or disabled');
		}
	} elsif ($args eq 'status') {
		_print_status();
	} elsif ($args eq 'trade' || $args eq 'trade status') {
		_print_trade_status();
	} elsif ($args eq 'trade reset') {
		econ_log('[CMD] rebuild trade state machine');
		_build_trade();
	} elsif ($args eq 'open') {
		econ_log('[CMD] force open buying store');
		$state{last_open_try} = 0;
		$state{open_fail_streak} = 0;
		main::openBuyerShop();
	} elsif ($args eq 'close') {
		econ_log('[CMD] force close buying store');
		main::closeBuyerShop();
	} elsif ($args eq 'reset') {
		$state{purchases} = 0;
		$state{spent_zeny} = 0;
		$state{open_fail_streak} = 0;
		$state{last_close_reason} = '';
		econ_log('[CMD] session statistics reset');
	} else {
		econ_log('[HELP] economy status | open | close | reset | classify | trade [status|reset]');
	}
}

sub on_unload {
	Plugins::delHooks($hooks) if $hooks;
	Commands::unregister($commands) if $commands;
	econ_log('[PLUGIN] unloaded');
}

load_item_catalog();
_build_trade();

1;
