package economy;

use strict;
use warnings;
no warnings 'redefine';

use AI;
use Commands;
use Globals qw($char $field $net %config $buyershopstarted $shopstarted);
use Log qw(message warning);
use Network;
use Plugins;
use Time::HiRes qw(time);

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

sub on_buyer_shop_closed {
	$state{closed_at} = time;
	econ_log('[STATE] buyer shop closed');
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

	if ($args eq 'status') {
		_print_status();
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
		econ_log('[HELP] economy status | open | close | reset');
	}
}

sub on_unload {
	Plugins::delHooks($hooks) if $hooks;
	Commands::unregister($commands) if $commands;
	econ_log('[PLUGIN] unloaded');
}

1;
