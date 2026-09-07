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
use Economy::Inventory;

my $catalog = {};
my %classification_cache;
my $gear_snapshot = q{};
sub _gear_snapshot {
    return q{} unless _in_game() && $char->inventory->isReady;
    return join(q{|}, map { join(q{:}, $_->{binID}, Economy::Inventory::signature($_), $_->{equipped}||0) }
        grep { ($catalog->{$_->{nameID}}{Type}||q{}) =~ /^(Weapon|Armor)$/ } @{$char->inventory->getItems});
}
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
    $gear_snapshot = _gear_snapshot();
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
our $VERSION = '1.1.0';

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

Plugins::register($NAME, 'Economy V1 classification and safe multi-item Trade', \&on_unload, \&on_unload);

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
	['packet/deal_add_other', \&on_trade_other_item],
	['packet/deal_add_you', \&on_trade_own_ack],
	['zeny_change', \&on_trade_zeny],
	['Network::stateChanged', \&on_trade_connection],
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

	return if _trade_enabled() || _trade_active();
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
# 阶段 5–6 —— 安全普通 Trade 与最多 10 项的顺序拆批。
#
# 用 Economy::Trade（纯状态机）驱动真实 Trade 协议：
#   seller: 分段发送清单 → READY → 逐项加物/ACK → 核对报价 → 锁定 → 提交 → 核对资产
#   buyer : 白名单/nonce/容量 → READY → 核对真实实例 → 报价 → 等卖家锁定 → 提交 → 核对资产
#
# 配置（config.txt）：
#   economy_trade_enabled 1           # 总开关
#   economy_trade_role seller         # seller | buyer
#   固定价格统一读取 trade_prices.json（nameID -> 每件 Zeny）
#   economy_trade_merchant Cartwright # seller 用：商人名
#   economy_trade_sellers Penny       # buyer 用：卖家白名单（逗号分隔）
#   economy_trade_timeout 30          # 状态 watchdog 秒
#   economy_trade_cooldown 15         # 成交/回滚已核对后的冷却秒
############################################################################

my $trade;               # Economy::Trade 实例
my $trade_last_tick = 0;
my ($policy, $pending_item, $server_zeny);
my $zeny_version = 0;
my @trade_pm_queue;
my $last_pm = 0;
sub _trade_active { return $trade && $trade->active; }

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
    if ($trade && $trade->active) {
        _execute_trade_actions($trade->abort('RESET_REQUESTED'));
        econ_warn('[TRADE] active session retained for reconciliation; reset after it is idle');
        return;
    }
    $trade = undef;
    @trade_pm_queue=();
    return unless _trade_enabled() && _trade_role();
    my $prices;
    eval {
        open my $fh, '<', dirname(__FILE__).'/trade_prices.json' or die $!;
        $prices=decode_json(do {local $/; <$fh>});
        die 'price table must be object' unless ref($prices) eq 'HASH';
        1;
    } or do {econ_warn("[TRADE] price table unavailable: $@"); return;};
    $policy=Economy::Inventory->new(catalog=>$catalog, npc_rules=>\%items_control, prices=>$prices);
    $trade=Economy::Trade->new(role=>_trade_role(), policy=>$policy,
        merchant=>$config{economy_trade_merchant}||'', sellers=>_trade_sellers(),
        timeout=>_trade_num('economy_trade_timeout')||30,
        cooldown=>_trade_num('economy_trade_cooldown')||15);
    econ_log('[TRADE] initialized multi-item protocol; shared fixed price table');
}
sub on_postloadfiles { load_item_catalog(); _build_trade(); }
sub _feed_trade {
    my ($method,@args)=@_;
    return unless $trade;
    _execute_trade_actions($trade->$method(@args));
}
sub _peer {
    my ($name)=@_;
    return unless $playersList && $name;
    my ($p)=grep {$_->name eq $name} @$playersList;
    return $p;
}
sub _trade_context {
    my ($name)=@_;
    return {} unless _in_game() && $char->inventory->isReady;
    my $peer=_peer($name);
    my $near=0;
    if ($peer && $peer->{pos_to} && $char->{pos_to}) {
        my $dx=abs($peer->{pos_to}{x}-$char->{pos_to}{x});
        my $dy=abs($peer->{pos_to}{y}-$char->{pos_to}{y});
        $near=$dx<=2 && $dy<=2;
    }
    # Stage 7 owns roaming/world_ai integration. Until then, only stationary,
    # explicitly configured probes may initiate or accept economic sessions.
    my $safe=_trade_enabled() && !$shopstarted && !$buyershopstarted && !$char->{sitting}
        && !$config{world_ai_auto_execute}
        && !AI::inQueue(qw(attack skill_use route mapRoute move storageAuto buyAuto sellAuto NPC teleport));
    my $items=$char->inventory->getItems;
    my $cart=$char->cart;
    my $cart_items=$cart && $cart->isReady ? $cart->getItems : [];
    my $gear_ready=$gear_snapshot ne '' && $gear_snapshot eq _gear_snapshot();
    my $candidates=$policy ? $policy->candidates($items,$gear_ready) : [];
    my $incoming_ok=!%incomingDeal || ($incomingDeal{name}||'') eq ($name||'');
    my $ctx={safe=>$safe && !%currentDeal && !%outgoingDeal && $incoming_ok, trade_safe=>$safe,
        self_name=>$char->{name}||'', peer_near=>$near, peer_name=>$currentDeal{name}||'', candidates=>$candidates,
        deal_active=>(%currentDeal || %outgoingDeal || %incomingDeal)?1:0,
        snapshot=>Economy::Inventory::snapshot($items,$char->{zeny},$cart_items),
        zeny_version=>$zeny_version,server_zeny=>$server_zeny,
        other_zeny=>$currentDeal{other_zeny}||0,
        other_item_count=>scalar keys %{$currentDeal{other}||{}},
        own_finalized=>$currentDeal{you_finalize}||0, other_finalized=>$currentDeal{other_finalize}||0};
    # Reserve Cart room for ALL already acquired priced stock still in inventory.
    my $pending=$policy ? $policy->candidates($items,1) : [];
    my $pending_weight=0;
    my (%inv_amounts,%cart_amounts);
    $inv_amounts{$_->{nameID}}+=$_->{amount} for @$items;
    $cart_amounts{$_->{nameID}}+=$_->{amount} for @$cart_items;
    for my $i (@$pending) {
        $pending_weight+=($catalog->{$i->{nameID}}{Weight}||0)*$i->{amount}/10;
        $cart_amounts{$i->{nameID}}+=$i->{amount};
    }
    $ctx->{capacity}={ready=>($cart && $cart->isReady && $char->{weight_max} && $cart->{weight_max})?1:0,
        zeny=>$char->{zeny}, inventory_free=>100-$char->inventory->size,
        weight=>($char->{weight}||0)+1, weight_max=>$char->{weight_max}||0,
        cart_free=>($cart ? $cart->items_max-$cart->size : 0)-scalar(@$pending),
        cart_weight=>($cart ? $cart->{weight} : 0)+$pending_weight+1,
        cart_weight_max=>$cart ? $cart->{weight_max} : 0,
        inventory_amounts=>\%inv_amounts,cart_amounts=>\%cart_amounts};
    return $ctx;
}
sub _execute_trade_actions {
    my ($actions)=@_;
    for my $a (@{$actions||[]}) {
        my $t=$a->{type};
        if ($t eq 'log') {econ_log($a->{msg}); next;}
        if ($t eq 'send_pm') {push @trade_pm_queue,$a; next;}
        next unless _in_game();
        if ($t eq 'cancel_deal') {
            @trade_pm_queue=(); $pending_item=undef;
            if (%currentDeal) {$messageSender->sendCurrentDealCancel();}
            elsif (%incomingDeal || %outgoingDeal) {$messageSender->sendDealReply(4);}
            else {_feed_trade('on_cancelled');}
        } elsif ($t eq 'reject_request') {
            $messageSender->sendDealReply(4) unless %currentDeal;
        } elsif ($t eq 'accept_deal') {$messageSender->sendDealReply(3);}
        elsif ($t eq 'initiate_deal') {
            my $p=_peer($a->{name});
            if ($p) {main::deal($p);} else {_feed_trade('abort','PEER_MISSING');}
        } elsif ($t eq 'add_item') {
            my $item=$char->inventory->get($a->{slot});
            my $gear_ready=$gear_snapshot ne '' && $gear_snapshot eq _gear_snapshot();
            if (!$item || Economy::Inventory::signature($item) ne $a->{sig} || $item->{amount}<$a->{amount}
                || !$policy->eligible($item,$gear_ready)) {
                _feed_trade('abort','INVENTORY_CHANGED'); next;
            }
            $pending_item={%$a, wire_id=>$item->{ID}};
            main::dealAddItem($item,$a->{amount});
        } elsif ($t eq 'add_zeny') {
            $currentDeal{you_zeny}=$a->{amount}; # Native protocol offer, never an asset ledger.
            $messageSender->sendDealAddItem(pack('v',0),$a->{amount});
        } elsif ($t eq 'finalize') {$messageSender->sendDealFinalize();}
        elsif ($t eq 'commit') {$messageSender->sendDealTrade();}
    }
}
sub on_trade_pm {
    my (undef,$a)=@_;
    _feed_trade('on_pm',$a->{privMsgUser},$a->{privMsg},_trade_context($a->{privMsgUser}));
}
sub on_trade_incoming {
    my (undef,$a)=@_;
    _feed_trade('on_incoming_deal',$a->{name},_trade_context($a->{name}));
}
sub on_trade_engaged {
    my (undef,$a)=@_;
    _feed_trade('on_engaged',$a->{name},_trade_context($a->{name}));
}
sub on_trade_other_item {
    my (undef,$a)=@_;
    _feed_trade('on_other_item',$a) if $a->{nameID};
}
sub on_trade_own_ack {
    my (undef,$a)=@_;
    return unless $trade && $trade->active;
    if ($a->{fail} && $a->{fail}!=192) {_feed_trade('abort','ADD_FAILED_'.$a->{fail}); return;}
    if (unpack('v',$a->{ID})==0) {_feed_trade('on_own_zeny'); return;}
    my $p=$pending_item; $pending_item=undef;
    unless ($p && $a->{ID} eq $p->{wire_id}) {_feed_trade('abort','UNEXPECTED_ACK'); return;}
    # Packet handler has already removed this item locally. Pass the immutable
    # sent instance; only now may the next add overwrite lastItemAmount.
    if ($gear_snapshot ne '') {
        my $expected=join('|',grep {index($_,$p->{slot}.':'.$p->{sig}.':')!=0} split /\|/,$gear_snapshot);
        $gear_snapshot=$expected if $expected eq _gear_snapshot();
    }
    _feed_trade('on_own_item',@$p{qw(slot sig amount)});
}
sub on_trade_zeny {my (undef,$a)=@_; $server_zeny=$a->{zeny}; $zeny_version++;}
sub on_trade_connection {
    return if _in_game();
    @trade_pm_queue=(); $pending_item=undef; $gear_snapshot='';
    _feed_trade('on_disconnected');
}
sub on_trade_finalized { on_trade_tick(1); }
sub on_trade_complete { _feed_trade('on_complete'); on_trade_tick(1); }
sub on_trade_cancelled { $pending_item=undef; @trade_pm_queue=(); _feed_trade('on_cancelled'); }
sub on_trade_error {my (undef,$a)=@_; _feed_trade('on_error',$a->{type});}
sub _send_trade_pm {
    my ($a)=@_;
    return unless _in_game() && length($a->{msg})<=240;
    # Misc::sendMessage defaults to 80-char word splitting, which corrupts
    # manifest fingerprints. The native sender preserves one protocol frame.
    Misc::sendMessage_send($messageSender,'pm',$a->{msg},$a->{to});
}
sub on_trade_tick {
    my ($force)=@_;
    return unless $trade && _in_game();
    my $now=time;
    return if !$force && $now-$trade_last_tick<1;
    $trade_last_tick=$now;
    if (!_trade_enabled()) {_feed_trade('abort','DISABLED');}
    my $ctx=_trade_context($trade->counterpart || $config{economy_trade_merchant});
    _feed_trade('tick',now=>$now,%$ctx);
    # Pace manifest messages to avoid server private-message flood limits.
    if (@trade_pm_queue && $now-$last_pm>=1) {
        my $a=shift @trade_pm_queue;
        _send_trade_pm($a); $last_pm=$now;
    }
}

sub _print_trade_status {
    return econ_log('[TRADE] disabled') unless $trade;
    econ_log('[TRADE] role='._trade_role().' state='.$trade->state.' tx='.$trade->nonce.' peer='.$trade->counterpart);
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
	} elsif ($args eq 'trade reconcile') {
        _feed_trade('reconcile',_trade_context($trade ? $trade->counterpart : ''));
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
		econ_log('[HELP] economy status | open | close | reset | classify | trade [status|reset|reconcile]');
	}
}

sub on_unload {
	_feed_trade('abort','PLUGIN_UNLOAD');
	@trade_pm_queue=();
	Plugins::delHooks($hooks) if $hooks;
	Commands::unregister($commands) if $commands;
	econ_log('[PLUGIN] unloaded');
}

load_item_catalog();
_build_trade();

1;
