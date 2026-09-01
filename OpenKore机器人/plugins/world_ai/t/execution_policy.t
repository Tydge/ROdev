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

done_testing;
