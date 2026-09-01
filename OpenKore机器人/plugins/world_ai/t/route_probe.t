use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use WorldAI::RouteProbe;
use WorldAI::ExecutionPolicy;

{
	package Local::Task;

	sub new {
		my ($class, %args) = @_;
		return bless {
			status => 0,
			iterations => 0,
			finish_after => $args{finish_after},
			error => $args{error},
			route => $args{route},
			route_string => $args{route_string},
			time_ref => $args{time_ref},
			advance => $args{advance} || 0,
			die_on_iterate => $args{die_on_iterate},
		}, $class;
	}

	sub activate { $_[0]{status} = 1 }
	sub getStatus { $_[0]{status} }
	sub stop { $_[0]{status} = 3 }
	sub iterate {
		my ($self) = @_;
		die "iterate exploded" if $self->{die_on_iterate};
		${$self->{time_ref}} += $self->{advance} if $self->{time_ref};
		$self->{iterations}++;
		$self->{status} = 4 if defined($self->{finish_after}) && $self->{iterations} >= $self->{finish_after};
	}
	sub getError { $_[0]{error} }
	sub getRoute { $_[0]{route} }
	sub getRouteString { $_[0]{route_string} }
}

sub make_probe {
	my (%args) = @_;
	my $now = 0;
	my @created;
	my $probe = WorldAI::RouteProbe->new(
		done_status => 4,
		running_status => 1,
		clock => sub { $now },
		task_factory => sub {
			my %task_args = @_;
			push @created, \%task_args;
			return Local::Task->new(
				%args,
				time_ref => \$now,
			);
		},
		wall_timeout_ms => $args{wall_timeout_ms} || 1000,
		task_slice_s => 0.03,
	);
	return ($probe, \@created, \$now);
}

subtest 'same map is reachable without constructing CalcMapRoute' => sub {
	my ($probe, $created) = make_probe();
	my $result = $probe->probe(
		map => 'prt_fild08', source_map => 'prt_fild08', source_x => 170, source_y => 350, budget => 500,
	);
	is($result->{status}, 'REACHABLE', 'same map is reachable');
	is($result->{route_hops}, 0, 'same map has zero hops');
	is($result->{route_weighted_cost}, 0, 'same map has zero weighted cost');
	is(scalar(@$created), 0, 'task factory was not called');
};

subtest 'reachable route uses cumulative metadata from final step' => sub {
	my $route = [
		{ map => 'prt_fild08', pos => {x => 16, y => 239}, walk => 90, zeny => 0, amount_of_tickets_used => 0 },
		{ map => 'prt_fild07', pos => {x => 84, y => 13}, walk => 240, zeny => 120, amount_of_tickets_used => 1,
		  steps => ['c r0'], is_airship => 1 },
	];
	my ($probe, $created) = make_probe(
		finish_after => 1,
		route => $route,
		route_string => 'prt_fild08 -> prt_fild07 -> prt_fild09',
	);
	my $result = $probe->probe(
		map => 'prt_fild09', source_map => 'prt_fild08', source_x => 170, source_y => 350, budget => 500,
	);
	is($result->{status}, 'REACHABLE', 'route is reachable');
	is($result->{route_hops}, 2, 'route steps are counted as hops');
	is($result->{route_weighted_cost}, 240, 'final cumulative walk is used');
	is($result->{route_zeny}, 120, 'final cumulative zeny is used');
	is($result->{route_tickets}, 1, 'final cumulative ticket count is used');
	is($result->{uses_npc}, 1, 'NPC steps detected');
	is($result->{uses_airship}, 1, 'airship detected');
	is($created->[0]{maxTime}, 0.03, 'small internal calculation slice passed');
	is($created->[0]{budget}, 500, 'current character budget passed');
};

subtest 'execution route flags are passed to CalcMapRoute' => sub {
	my ($probe, $created) = make_probe(
		finish_after => 1,
		route => [{ map => 'start', walk => 10, zeny => 0, amount_of_tickets_used => 0 }],
		route_string => 'start -> target',
	);
	$probe->probe(
		map => 'target', source_map => 'start', source_x => 1, source_y => 2,
		budget => 0, noGoCommand => 1, noTeleSpawn => 1, noWarpItem => 1, noAirship => 1,
	);
	is($created->[0]{budget}, 0, 'zero budget is preserved');
	for my $flag (qw(noGoCommand noTeleSpawn noWarpItem noAirship)) {
		is($created->[0]{$flag}, 1, "$flag is passed");
	}
};

subtest 'explicit route failures are unreachable' => sub {
	my ($probe) = make_probe(
		finish_after => 1,
		error => { code => 'CANNOT_CALCULATE_ROUTE', message => 'no route' },
	);
	my $result = $probe->probe(
		map => 'unreachable', source_map => 'prt_fild08', source_x => 170, source_y => 350,
	);
	is($result->{status}, 'UNREACHABLE', 'explicit calculation failure is unreachable');
	is($result->{error_code}, 'CANNOT_CALCULATE_ROUTE', 'error code preserved');
};

subtest 'timeout and exception are unknown' => sub {
	my ($slow_probe) = make_probe(finish_after => undef, advance => 0.6);
	my $timeout = $slow_probe->probe(
		map => 'pay_fild08', source_map => 'prt_fild08', source_x => 170, source_y => 350,
	);
	is($timeout->{status}, 'UNKNOWN', 'timeout is unknown');
	is($timeout->{error_code}, 'TIMEOUT', 'timeout code returned');

	my ($broken_probe) = make_probe(finish_after => 1, die_on_iterate => 1);
	my $broken = $broken_probe->probe(
		map => 'pay_fild08', source_map => 'prt_fild08', source_x => 170, source_y => 350,
	);
	is($broken->{status}, 'UNKNOWN', 'task exception is unknown');
	is($broken->{error_code}, 'TASK_EXCEPTION', 'task exception is classified');
};

{
	package Local::SelectorProbe;
	use parent 'WorldAI::RouteProbe';
	sub probe {
		my ($self, %args) = @_;
		$self->{calls}{$args{map}}++;
		${$self->{time_ref}} += $self->{advance} if $self->{time_ref};
		return $self->{responses}{$args{map}};
	}
}

subtest 'candidate fallback deduplicates maps' => sub {
	my $probe = Local::SelectorProbe->new(
		clock => sub { 0 },
		responses => {},
	);
	$probe->{responses} = {
		map_a => { status => 'UNREACHABLE', target_map => 'map_a', engine => 'Task::CalcMapRoute' },
		map_b => { status => 'REACHABLE', target_map => 'map_b', engine => 'Task::CalcMapRoute' },
	};
	my $candidates = [
		{ monster_id => 1, target_map => 'map_a', score => 90 },
		{ monster_id => 2, target_map => 'map_a', score => 89 },
		{ monster_id => 3, target_map => 'map_b', score => 80 },
	];
	my $selected = $probe->first_reachable(
		candidates => $candidates,
		source_map => 'start', source_x => 1, source_y => 2,
		max_probes => 8, total_timeout_ms => 2000,
	);
	is($selected->{selected}{monster_id}, 3, 'first candidate on a reachable map selected');
	is($selected->{probes_used}, 2, 'only unique maps probed');
	is($probe->{calls}{map_a}, 1, 'duplicate unreachable map reused');
	is($selected->{attempts}[1]{cached}, 1, 'cached attempt is marked');
};

subtest 'candidate probe count limit is explicit' => sub {
	my $probe = Local::SelectorProbe->new(clock => sub { 0 });
	$probe->{responses} = {
		map_a => { status => 'UNKNOWN' },
		map_b => { status => 'REACHABLE' },
	};
	my $selected = $probe->first_reachable(
		candidates => [ { target_map => 'map_a' }, { target_map => 'map_b' } ],
		source_map => 'start', source_x => 1, source_y => 2,
		max_probes => 1, total_timeout_ms => 2000,
	);
	ok(!$selected->{selected}, 'nothing selected beyond probe limit');
	ok($selected->{limit_reached}, 'probe limit is reported');
};

subtest 'candidate total command budget is explicit' => sub {
	my $now = 0;
	my $probe = Local::SelectorProbe->new(clock => sub { $now });
	$probe->{time_ref} = \$now;
	$probe->{advance} = 1.1;
	$probe->{responses} = {
		map_a => { status => 'UNKNOWN' },
		map_b => { status => 'REACHABLE' },
	};
	my $selected = $probe->first_reachable(
		candidates => [ { target_map => 'map_a' }, { target_map => 'map_b' } ],
		source_map => 'start', source_x => 1, source_y => 2,
		max_probes => 8, total_timeout_ms => 1000,
	);
	ok(!$selected->{selected}, 'nothing selected beyond total command budget');
	ok($selected->{budget_reached}, 'total command budget is reported');
	is($selected->{probes_used}, 1, 'no second map is probed after budget');
};

subtest 'executable selector skips reachable policy rejection' => sub {
	my $probe = Local::SelectorProbe->new(clock => sub { 0 });
	$probe->{responses} = {
		paid_map => {
			status => 'REACHABLE', route_zeny => 2000, route_tickets => 0,
			uses_npc => 1, uses_command => 0, uses_airship => 0,
			uses_save_teleport => 0, uses_warp_item => 0,
		},
		free_map => {
			status => 'REACHABLE', route_zeny => 0, route_tickets => 0,
			uses_npc => 0, uses_command => 0, uses_airship => 0,
			uses_save_teleport => 0, uses_warp_item => 0,
		},
	};
	my $selected = $probe->first_executable(
		candidates => [
			{ monster_id => 1, target_map => 'paid_map' },
			{ monster_id => 2, target_map => 'free_map' },
		],
		policy => WorldAI::ExecutionPolicy->new(allow_npc => 0),
		source_map => 'start', source_x => 1, source_y => 2,
	);
	is($selected->{selected}{monster_id}, 2, 'free candidate after rejected reachable route is selected');
	ok(!$selected->{attempts}[0]{policy}{allowed}, 'first reachable route is policy-rejected');
	ok($selected->{attempts}[1]{policy}{allowed}, 'second route is policy-allowed');
};

done_testing;
