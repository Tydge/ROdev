use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";

use WorldAI::ExecutionPolicy;

my $policy = WorldAI::ExecutionPolicy->new(allow_npc => 0);
is_deeply(
	$policy->route_options,
	{ budget => 0, noGoCommand => 1, noTeleSpawn => 1, noWarpItem => 1, noAirship => 1 },
	'execution route calculation disables paid and special travel branches',
);

my $free_portal = {
	status => 'REACHABLE', route_zeny => 0, route_tickets => 0,
	uses_npc => 0, uses_command => 0, uses_airship => 0,
	uses_save_teleport => 0, uses_warp_item => 0,
};
ok($policy->evaluate($free_portal)->{allowed}, 'free portal route is allowed');

for my $case (
	['route_zeny_nonzero', route_zeny => 1],
	['route_tickets_nonzero', route_tickets => 1],
	['npc_route_disabled', uses_npc => 1],
	['command_route_disabled', uses_command => 1],
	['airship_route_disabled', uses_airship => 1],
	['save_teleport_disabled', uses_save_teleport => 1],
	['warp_item_disabled', uses_warp_item => 1],
) {
	my ($reason, $key, $value) = @$case;
	my $route = { %$free_portal, $key => $value };
	my $result = $policy->evaluate($route);
	ok(!$result->{allowed}, "$reason is rejected");
	is($result->{reasons}[0], $reason, "$reason is explicit");
}

my $unreachable = $policy->evaluate({ status => 'UNREACHABLE' });
ok(!$unreachable->{allowed}, 'unreachable route is rejected');
is($unreachable->{reasons}[0], 'route_not_reachable', 'reachability failure is explicit');

my $hop_policy = WorldAI::ExecutionPolicy->new(allow_npc => 0, max_hops => 3);
my $far = $hop_policy->evaluate({ %$free_portal, route_hops => 8 });
ok(!$far->{allowed}, 'route beyond max hops is rejected');
is($far->{reasons}[0], 'route_hops_exceeded', 'hop limit rejection is explicit');
ok($hop_policy->evaluate({ %$free_portal, route_hops => 3 })->{allowed}, 'route within max hops is allowed');
ok($hop_policy->evaluate({ %$free_portal, route_hops => 0 })->{allowed}, 'same-map route is allowed');

my $unlimited = WorldAI::ExecutionPolicy->new(allow_npc => 0);
ok($unlimited->evaluate({ %$free_portal, route_hops => 8 })->{allowed}, 'no hop limit by default');

# --- configurable hops (Step 4A.2: default 6) ---
my $six = WorldAI::ExecutionPolicy->new(allow_npc => 0, max_hops => 6);
ok($six->evaluate({ %$free_portal, route_hops => 3 })->{allowed}, '3 hops allowed under max 6');
ok($six->evaluate({ %$free_portal, route_hops => 4 })->{allowed}, '4 hops allowed under max 6');
ok($six->evaluate({ %$free_portal, route_hops => 6 })->{allowed}, '6 hops allowed under max 6');
ok(!$six->evaluate({ %$free_portal, route_hops => 7 })->{allowed}, '7 hops rejected under max 6');

my $four = WorldAI::ExecutionPolicy->new(allow_npc => 0, max_hops => 4);
ok($four->evaluate({ %$free_portal, route_hops => 4 })->{allowed}, 'custom max 4 allows 4 hops');
ok(!$four->evaluate({ %$free_portal, route_hops => 5 })->{allowed}, 'custom max 4 rejects 5 hops');

# --- normalize_max_hops validation ---
is(WorldAI::ExecutionPolicy->normalize_max_hops('6'), 6, 'valid hops string normalizes');
is(WorldAI::ExecutionPolicy->normalize_max_hops(6), 6, 'valid hops number normalizes');
is(WorldAI::ExecutionPolicy->normalize_max_hops('1'), 1, 'min hops is 1');
is(WorldAI::ExecutionPolicy->normalize_max_hops('10'), 10, 'max hops is 10');
is(WorldAI::ExecutionPolicy->normalize_max_hops('0'), undef, 'zero is invalid');
is(WorldAI::ExecutionPolicy->normalize_max_hops('-1'), undef, 'negative is invalid');
is(WorldAI::ExecutionPolicy->normalize_max_hops('11'), undef, 'above max is invalid');
is(WorldAI::ExecutionPolicy->normalize_max_hops('abc'), undef, 'non-numeric is invalid');
is(WorldAI::ExecutionPolicy->normalize_max_hops(''), undef, 'empty is invalid');
is(WorldAI::ExecutionPolicy->normalize_max_hops(undef), undef, 'undef is invalid');

done_testing;
