use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Economy::Trade;

# 用可注入的时钟与 nonce 做确定性测试。
my $CLOCK = 1000;
sub fake_now { return $CLOCK; }

sub seller {
	return Economy::Trade->new(
		role => 'seller', item_id => 4023, price => 10000,
		merchant => 'Cartwright', nonce_fn => sub { 'deadbeef' }, now_fn => \&fake_now,
		timeout => 30, cooldown => 15,
	);
}
sub buyer {
	return Economy::Trade->new(
		role => 'buyer', item_id => 4023, price => 10000,
		sellers => { Penny => 1 }, nonce_fn => sub { 'deadbeef' }, now_fn => \&fake_now,
		timeout => 30, cooldown => 15,
	);
}
sub acts_of {
	my ($list, $type) = @_;
	return [ grep { $_->{type} eq $type } @$list ];
}

# ---- seller 全流程 ----
{
	my $s = seller();
	is($s->state, 'idle', 'seller starts idle');

	my $a = $s->tick(now => $CLOCK, has_card => 0);
	is_deeply($a, [], 'no card -> no action');

	$a = $s->tick(now => $CLOCK, has_card => 1, card_index => 4);
	is($s->state, 'wait_ready', 'seller auto-starts on card');
	my $pm = acts_of($a, 'send_pm');
	is(scalar @$pm, 1, 'sends one pm');
	is($pm->[0]{to}, 'Cartwright', 'pm to merchant');
	is($pm->[0]{msg}, 'SELL_REQUEST deadbeef 4023', 'pm format SELL_REQUEST nonce itemID');

	# 错误 nonce / 错误来源的 READY 被忽略。
	is_deeply($s->on_pm('Cartwright', 'READY wrongnonce'), [], 'wrong nonce READY ignored');
	is($s->state, 'wait_ready', 'still waiting');
	is_deeply($s->on_pm('SomeoneElse', 'READY deadbeef'), [], 'wrong sender READY ignored');

	my $b = $s->on_pm('Cartwright', 'READY deadbeef');
	is($s->state, 'initiating', 'valid READY -> initiating');
	is_deeply(acts_of($b, 'initiate_deal'), [{ type => 'initiate_deal', name => 'Cartwright' }], 'initiates trade');

	is_deeply($s->on_engaged('WrongName'), [], 'wrong engaged name ignored');
	my $e = $s->on_engaged('Cartwright');
	is($s->state, 'engaged', 'engaged with merchant');
	is_deeply(acts_of($e, 'add_item'), [{ type => 'add_item', nameID => 4023, amount => 1 }], 'seller adds card on engage');

	# 错误报价 → 拒绝。
	my $w = $s->tick(now => $CLOCK, other_zeny => 9999);
	is($s->state, 'error', 'wrong quote rejected');
	is(scalar @{acts_of($w, 'reject_deal')}, 1, 'wrong quote sends reject');
}

# ---- seller 正确报价 + 提交 ----
{
	my $s = seller();
	$s->tick(now => $CLOCK, has_card => 1, card_index => 4);
	$s->on_pm('Cartwright', 'READY deadbeef');
	$s->on_engaged('Cartwright');
	my $q = $s->tick(now => $CLOCK, other_zeny => 10000);
	is($s->state, 'quoted', 'correct quote -> quoted');
	is_deeply(acts_of($q, 'finalize'), [{ type => 'finalize' }], 'finalizes on correct quote');

	my $f = $s->on_other_finalized();
	is($s->state, 'committing', 'counterpart finalized -> committing');
	is_deeply(acts_of($f, 'commit'), [{ type => 'commit' }], 'commits');

	my $c = $s->on_complete();
	is($s->state, 'done', 'complete -> done');
	like($c->[0]{msg}, qr/complete/, 'completion logged');
}

# ---- seller 竞态：对方先锁定，seller 检测到报价时直接锁定+提交 ----
{
	my $s = seller();
	$s->tick(now => $CLOCK, has_card => 1, card_index => 4);
	$s->on_pm('Cartwright', 'READY deadbeef');
	$s->on_engaged('Cartwright');
	my $r = $s->tick(now => $CLOCK, other_zeny => 10000, other_finalized => 1);
	is($s->state, 'committing', 'seller skips quoted when counterpart already locked');
	is_deeply(acts_of($r, 'finalize'), [{ type => 'finalize' }], 'race: finalize emitted');
	is_deeply(acts_of($r, 'commit'), [{ type => 'commit' }], 'race: commit emitted');
}

# ---- buyer 白名单 / 校验 ----
{
	my $b = buyer();
	my $a = $b->on_pm('Stranger', 'SELL_REQUEST deadbeef 4023');
	is_deeply(acts_of($a, 'send_pm'), [], 'non-whitelisted ignored');
	is($b->state, 'idle', 'stays idle');

	$a = $b->on_pm('Penny', 'SELL_REQUEST deadbeef 9999');
	is_deeply(acts_of($a, 'send_pm'), [], 'wrong item rejected');
	is($b->state, 'idle', 'stays idle');

	$a = $b->on_pm('Penny', 'SELL_REQUEST deadbeef 4023');
	is($b->state, 'ready_sent', 'valid request -> ready_sent');
	is_deeply(acts_of($a, 'send_pm'), [{ type => 'send_pm', to => 'Penny', msg => 'READY deadbeef' }], 'replies READY');

	# 重放 nonce 被丢弃。
	$a = $b->on_pm('Penny', 'SELL_REQUEST deadbeef 4023');
	is($b->state, 'ready_sent', 'replayed nonce dropped');
	like($a->[0]{msg}, qr/replayed/, 'replay logged');
}

# ---- buyer 接单 + 付款 + 提交 ----
{
	my $b = buyer();
	$b->on_pm('Penny', 'SELL_REQUEST deadbeef 4023');
	is_deeply($b->on_incoming_deal('Stranger'), [], 'wrong incoming dealer ignored');
	my $a = $b->on_incoming_deal('Penny');
	is($b->state, 'accepting', 'whitelisted incoming -> accepting');
	is_deeply(acts_of($a, 'accept_deal'), [{ type => 'accept_deal' }], 'accepts');

	$b->on_engaged('Penny');
	is($b->state, 'engaged', 'engaged');

	# 错误数量 → 拒绝。
	my $bad = $b->tick(now => $CLOCK, other_items => { 4023 => { amount => 2 } });
	is($b->state, 'error', 'bad amount rejected');
	is(scalar @{acts_of($bad, 'reject_deal')}, 1, 'bad amount reject');
}

{
	my $b = buyer();
	$b->on_pm('Penny', 'SELL_REQUEST deadbeef 4023');
	$b->on_incoming_deal('Penny');
	$b->on_engaged('Penny');
	my $p = $b->tick(now => $CLOCK, other_items => { 4023 => { amount => 1 } });
	is($b->state, 'quoted', 'correct item -> quoted');
	is_deeply(acts_of($p, 'add_zeny'), [{ type => 'add_zeny', amount => 10000 }], 'adds zeny');
	is_deeply(acts_of($p, 'finalize'), [{ type => 'finalize' }], 'finalizes');

	$b->on_other_finalized();
	is($b->state, 'committing', 'committing');
	$b->on_complete();
	is($b->state, 'done', 'done');
}

# ---- watchdog 超时 ----
{
	my $s = seller();
	$s->tick(now => $CLOCK, has_card => 1, card_index => 4);
	is($s->state, 'wait_ready', 'waiting');
	my $later = $CLOCK + 31;
	my $a = $s->tick(now => $later);
	is($s->state, 'error', 'watchdog times out');
	like($a->[0]{msg}, qr/timeout/, 'timeout logged');
}

# ---- cooldown 自愈 ----
{
	my $s = seller();
	$s->tick(now => $CLOCK, has_card => 1, card_index => 4);
	$s->on_cancelled();
	is($s->state, 'error', 'cancelled -> error');
	is_deeply($s->tick(now => $CLOCK + 5, has_card => 1, card_index => 4), [], 'within cooldown no restart');
	is($s->state, 'error', 'still error during cooldown');
	my $a = $s->tick(now => $CLOCK + 16, has_card => 1, card_index => 4);
	is($s->state, 'wait_ready', 'after cooldown resets and restarts');
	is(scalar @{acts_of($a, 'send_pm')}, 1, 'restart sends request');
}

done_testing;
