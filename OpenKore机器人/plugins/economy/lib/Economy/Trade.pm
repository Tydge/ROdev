package Economy::Trade;
use strict;
use warnings;

# Economy V1 Sprint 8 —— 普通 Trade 自动收购状态机（纯逻辑，无 OpenKore 依赖）。
#
# 角色：
#   seller：持卡战斗侧（Combat Bot / probe），发起 SELL_REQUEST、发起 Trade、放卡、核对报价、锁定、确认。
#   buyer ：商人侧（Merchant），校验 SELL_REQUEST、回 READY、白名单接单、检测卡片、放 zeny、锁定、确认。
#
# 消息协议（私聊，空格分隔）：
#   seller -> buyer : SELL_REQUEST <nonce> <itemID>
#   buyer  -> seller: READY <nonce>
#
# 本模块只做决策，返回动作数组；economy.pl 负责把动作翻译成 OpenKore 调用。

use constant {
	ST_IDLE       => 'idle',
	ST_WAIT_READY => 'wait_ready',  # seller: 已发 SELL_REQUEST，等 READY
	ST_INITIATING => 'initiating',  # seller: 已发 Trade 请求，等 engage
	ST_READY_SENT => 'ready_sent',  # buyer:  已回 READY，等 incoming deal
	ST_ACCEPTING  => 'accepting',   # buyer:  已 accept，等 engage
	ST_ENGAGED    => 'engaged',     # 双方: 已成交中，等对方报价/物品
	ST_QUOTED     => 'quoted',      # 双方: 已锁定本方，等对方锁定
	ST_COMMITTING => 'committing',  # 双方: 已 commit，等 complete
	ST_DONE       => 'done',
	ST_ERROR      => 'error',
};

sub new {
	my ($class, %args) = @_;
	my $role = $args{role} || '';
	die "role must be seller|buyer" unless $role eq 'seller' || $role eq 'buyer';
	return bless {
		role      => $role,
		item_id   => 0 + ($args{item_id}  // 0),
		price     => 0 + ($args{price}    // 0),
		merchant  => $args{merchant} // '',                 # seller 用
		sellers   => $args{sellers}  // {},                 # buyer 白名单: name => 1
		nonce_fn  => $args{nonce_fn} // sub { _default_nonce() },
		now_fn    => $args{now_fn}   // sub { time },
		timeout   => $args{timeout}  // 30,
		cooldown  => $args{cooldown} // 15,
		state     => ST_IDLE,
		nonce     => '',
		counterpart => '',   # 本次会话对方角色名
		deadline  => 0,      # 当前状态超时点
		ended_at  => 0,      # 上次 done/error 时间（cooldown 用）
		seen_nonce => {},    # buyer: 已处理的 nonce（防重放）
	}, $class;
}

sub state { return $_[0]{state}; }
sub counterpart { return $_[0]{counterpart}; }
sub nonce { return $_[0]{nonce}; }

sub _default_nonce {
	my @c = ('0'..'9','a'..'f');
	return join '', map { $c[int(rand(@c))] } 1..8;
}

sub _now { return $_[0]{now_fn}->(); }

# 进入新状态并刷新超时点。
sub _enter {
	my ($self, $state) = @_;
	$self->{state} = $state;
	$self->{deadline} = $self->_now() + $self->{timeout};
}

sub _emit {
	my ($self, $log, @actions) = @_;
	return [ { type => 'log', msg => $log }, @actions ];
}

sub _reset {
	my ($self) = @_;
	$self->{state} = ST_IDLE;
	$self->{nonce} = '';
	$self->{counterpart} = '';
	$self->{deadline} = 0;
}

# ---------------------------------------------------------------------------
# 事件入口
# ---------------------------------------------------------------------------

sub on_pm {
	my ($self, $from, $msg) = @_;
	return [] if $from eq '' || !defined $msg;
	if ($self->{role} eq 'buyer') {
		return $self->_buyer_on_pm($from, $msg);
	}
	return $self->_seller_on_pm($from, $msg);
}

sub on_incoming_deal {
	my ($self, $name) = @_;
	return [] unless $self->{role} eq 'buyer';  # Sprint 8 单向：seller 不接受被动接单
	return $self->_buyer_on_incoming_deal($name);
}

sub on_engaged { return $_[0]->_on_engaged($_[1]); }

sub on_other_finalized {
	my ($self) = @_;
	return [] unless $self->{state} eq ST_QUOTED;
	$self->_enter(ST_COMMITTING);
	return $self->_emit('[TRADE] counterpart finalized; committing', { type => 'commit' });
}

sub on_complete {
	my ($self) = @_;
	return [] if $self->{state} eq ST_IDLE || $self->{state} eq ST_DONE;
	$self->{ended_at} = $self->_now();
	$self->{state} = ST_DONE;
	return $self->_emit(sprintf('[TRADE] complete: counterpart=%s itemID=%s price=%sz nonce=%s',
		$self->{counterpart}, $self->{item_id}, $self->{price}, $self->{nonce}));
}

sub on_cancelled {
	my ($self) = @_;
	return [] if $self->{state} eq ST_IDLE || $self->{state} eq ST_DONE;
	$self->{ended_at} = $self->_now();
	my $out = $self->_emit(sprintf('[TRADE] cancelled in state=%s', $self->{state}));
	$self->{state} = ST_ERROR;
	return $out;
}

sub on_error {
	my ($self, $type) = @_;
	return [] if $self->{state} eq ST_IDLE || $self->{state} eq ST_DONE;
	$self->{ended_at} = $self->_now();
	my $out = $self->_emit(sprintf('[TRADE] server rejected type=%s in state=%s', $type, $self->{state}));
	$self->{state} = ST_ERROR;
	return $out;
}

# ---------------------------------------------------------------------------
# seller
# ---------------------------------------------------------------------------

sub _seller_on_pm {
	my ($self, $from, $msg) = @_;
	return [] unless $self->{state} eq ST_WAIT_READY;
	return [] unless $self->{merchant} ne '' && $from eq $self->{merchant};
	my ($verb, $nonce) = split / /, $msg;
	return [] unless defined $verb && $verb eq 'READY' && defined $nonce && $nonce eq $self->{nonce};
	$self->_enter(ST_INITIATING);
	return $self->_emit(sprintf('[TRADE] seller got READY from %s; initiating trade', $from),
		{ type => 'initiate_deal', name => $from });
}

sub _on_engaged {
	my ($self, $name) = @_;
	if ($self->{role} eq 'seller') {
		return [] unless $self->{state} eq ST_INITIATING;
		return [] unless $self->{counterpart} ne '' && $name eq $self->{counterpart};
		$self->_enter(ST_ENGAGED);
		return $self->_emit(sprintf('[TRADE] engaged with %s; adding item and awaiting quote', $name),
			{ type => 'add_item', nameID => $self->{item_id}, amount => 1 });
	}
	return [] unless $self->{state} eq ST_ACCEPTING;
	return [] unless $self->{counterpart} ne '' && $name eq $self->{counterpart};
	$self->_enter(ST_ENGAGED);
	return $self->_emit(sprintf('[TRADE] engaged with %s; awaiting item', $name));
}

# ---------------------------------------------------------------------------
# buyer
# ---------------------------------------------------------------------------

sub _buyer_on_pm {
	my ($self, $from, $msg) = @_;
	my ($verb, $nonce, $item) = split / /, $msg;
	return [] unless defined $verb && $verb eq 'SELL_REQUEST';
	return [] unless defined $nonce && defined $item && $item =~ /^\d+$/;

	unless ($self->{sellers}{$from}) {
		return $self->_emit(sprintf('[TRADE] buyer ignored SELL_REQUEST from non-whitelisted %s', $from));
	}
	if (0 + $item != $self->{item_id}) {
		return $self->_emit(sprintf('[TRADE] buyer rejected SELL_REQUEST itemID=%s (want %s)', $item, $self->{item_id}));
	}
	return $self->_emit(sprintf('[TRADE] buyer dropped replayed nonce %s', $nonce)) if $self->{seen_nonce}{$nonce};
	# 一次只服务一个卖家。
	return $self->_emit('[TRADE] buyer busy; ignored new SELL_REQUEST') unless $self->{state} eq ST_IDLE;

	$self->{seen_nonce}{$nonce} = 1;
	$self->{nonce} = $nonce;
	$self->{counterpart} = $from;
	$self->_enter(ST_READY_SENT);
	return $self->_emit(sprintf('[TRADE] buyer accepted SELL_REQUEST from %s; sent READY', $from),
		{ type => 'send_pm', to => $from, msg => "READY $nonce" });
}

sub _buyer_on_incoming_deal {
	my ($self, $name) = @_;
	return [] unless $self->{state} eq ST_READY_SENT;
	return [] unless $self->{counterpart} ne '' && $name eq $self->{counterpart};
	$self->_enter(ST_ACCEPTING);
	return $self->_emit(sprintf('[TRADE] buyer accepting deal from whitelisted %s', $name),
		{ type => 'accept_deal' });
}

# ---------------------------------------------------------------------------
# tick：卖方自动启动 + 报价/物品轮询 + watchdog
# ---------------------------------------------------------------------------
#
# ctx 约定：
#   now             当前时间戳（必填）
#   has_card        seller 是否持有待售卡片
#   other_zeny      seller 看到的对方 zeny（核对报价）
#   other_items     buyer 看到的对方物品 { nameID => { amount => n } }
#   other_finalized 对方是否已锁定（用于处理“对方先于我们锁定”的时序竞态）
#
sub tick {
	my ($self, %ctx) = @_;
	my $now = $ctx{now} // $self->_now();

	# watchdog：活跃状态超时 → error。
	if ($self->{state} ne ST_IDLE && $self->{state} ne ST_DONE && $self->{state} ne ST_ERROR) {
		if ($now > $self->{deadline}) {
			$self->{ended_at} = $now;
			my $out = $self->_emit(sprintf('[TRADE] watchdog timeout in state=%s', $self->{state}));
			$self->{state} = ST_ERROR;
			return $out;
		}
	}

	return $self->{role} eq 'seller' ? $self->_seller_tick($now, %ctx) : $self->_buyer_tick($now, %ctx);
}

sub _cooldown_done {
	my ($self, $now) = @_;
	return $now - $self->{ended_at} >= $self->{cooldown};
}

sub _seller_tick {
	my ($self, $now, %ctx) = @_;

	if ($self->{state} eq ST_DONE || $self->{state} eq ST_ERROR) {
		return [] unless $self->_cooldown_done($now);
		$self->_reset();
		# 冷却结束后回 idle，同一 tick 内可立即进入下一轮。
	}

	if ($self->{state} eq ST_IDLE) {
		return [] unless $ctx{has_card};
		$self->{nonce} = $self->{nonce_fn}->();
		$self->{counterpart} = $self->{merchant};
		$self->_enter(ST_WAIT_READY);
		return $self->_emit(sprintf('[TRADE] seller requesting %s itemID=%s price=%sz nonce=%s',
			$self->{merchant}, $self->{item_id}, $self->{price}, $self->{nonce}),
			{ type => 'send_pm', to => $self->{merchant},
			  msg => sprintf('SELL_REQUEST %s %s', $self->{nonce}, $self->{item_id}) });
	}

	if ($self->{state} eq ST_ENGAGED) {
		my $zeny = 0 + ($ctx{other_zeny} // 0);
		if ($zeny > 0) {
			if ($zeny != $self->{price}) {
				$self->{ended_at} = $now;
				my $out = $self->_emit(sprintf('[TRADE] seller rejecting wrong quote %sz (want %sz)', $zeny, $self->{price}),
					{ type => 'reject_deal' });
				$self->{state} = ST_ERROR;
				return $out;
			}
			# 对方可能已先锁定（竞态）：直接锁定并提交，跳过 quoted 等待。
			if ($ctx{other_finalized}) {
				$self->_enter(ST_COMMITTING);
				return $self->_emit(sprintf('[TRADE] seller verified quote %sz and counterpart already locked; finalizing+committing', $zeny),
					{ type => 'finalize' }, { type => 'commit' });
			}
			$self->_enter(ST_QUOTED);
			return $self->_emit(sprintf('[TRADE] seller verified quote %sz; finalizing', $zeny),
				{ type => 'finalize' });
		}
	} elsif ($self->{state} eq ST_QUOTED) {
		if ($ctx{other_finalized}) {
			$self->_enter(ST_COMMITTING);
			return $self->_emit('[TRADE] counterpart locked; committing', { type => 'commit' });
		}
	}

	return [];
}

sub _buyer_tick {
	my ($self, $now, %ctx) = @_;

	if ($self->{state} eq ST_DONE || $self->{state} eq ST_ERROR) {
		return [] unless $self->_cooldown_done($now);
		$self->_reset();
		# 回 idle 后买方仅等待下一笔 SELL_REQUEST。
	}

	if ($self->{state} eq ST_ENGAGED) {
		my $items = $ctx{other_items} || {};
		my $entry = $items->{ $self->{item_id} };
		if ($entry && ($entry->{amount} || 0) > 0) {
			if ($entry->{amount} != 1) {
				$self->{ended_at} = $now;
				my $out = $self->_emit(sprintf('[TRADE] buyer rejecting bad amount %s (want 1)', $entry->{amount}),
					{ type => 'reject_deal' });
				$self->{state} = ST_ERROR;
				return $out;
			}
			my @pay = (
				{ type => 'add_zeny', amount => $self->{price} },
				{ type => 'finalize' },
			);
			# 竞态：对方已先锁定，则付款、锁定并直接提交。
			if ($ctx{other_finalized}) {
				$self->_enter(ST_COMMITTING);
				return $self->_emit(sprintf('[TRADE] buyer saw itemID=%s and counterpart locked; paying+finalizing+committing', $self->{item_id}),
					@pay, { type => 'commit' });
			}
			$self->_enter(ST_QUOTED);
			return $self->_emit(sprintf('[TRADE] buyer saw itemID=%s amount=1; paying %sz and finalizing',
				$self->{item_id}, $self->{price}),
				@pay);
		}
	} elsif ($self->{state} eq ST_QUOTED) {
		if ($ctx{other_finalized}) {
			$self->_enter(ST_COMMITTING);
			return $self->_emit('[TRADE] counterpart locked; committing', { type => 'commit' });
		}
	}

	return [];
}

1;
