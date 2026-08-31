package WorldAI::RouteProbe;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(time);

my $ENGINE = 'Task::CalcMapRoute';

sub new {
	my ($class, %args) = @_;
	return bless {
		wall_timeout_ms => defined($args{wall_timeout_ms}) ? $args{wall_timeout_ms} : 1000,
		task_slice_s    => defined($args{task_slice_s}) ? $args{task_slice_s} : 0.03,
		task_factory    => $args{task_factory},
		snapshot_provider => $args{snapshot_provider},
		clock           => $args{clock} || sub { time },
		done_status     => $args{done_status},
		running_status  => $args{running_status},
	}, $class;
}

sub _elapsed_ms {
	my ($self, $started) = @_;
	return int(($self->{clock}->() - $started) * 1000 + 0.5);
}

sub _result {
	my ($self, %args) = @_;
	return {
		status               => $args{status} || 'UNKNOWN',
		source_map           => $args{source_map},
		source_x             => $args{source_x},
		source_y             => $args{source_y},
		target_map           => $args{target_map},
		engine               => $ENGINE,
		route                => $args{route},
		route_string         => $args{route_string},
		route_hops           => $args{route_hops},
		route_weighted_cost  => $args{route_weighted_cost},
		route_zeny           => $args{route_zeny},
		route_tickets        => $args{route_tickets},
		uses_npc             => $args{uses_npc},
		uses_command         => $args{uses_command},
		uses_airship         => $args{uses_airship},
		uses_save_teleport   => $args{uses_save_teleport},
		uses_warp_item       => $args{uses_warp_item},
		error_code           => $args{error_code},
		error_message        => $args{error_message},
		elapsed_ms           => $args{elapsed_ms},
	};
}

sub _snapshot {
	my ($self) = @_;
	if ($self->{snapshot_provider}) {
		return $self->{snapshot_provider}->();
	}
	require WorldAI::CharacterSnapshot;
	return WorldAI::CharacterSnapshot::capture();
}

sub _source {
	my ($self, $args) = @_;
	if (defined($args->{source_map}) || defined($args->{source_x}) || defined($args->{source_y})) {
		return (undef, 'source map or coordinates are unavailable')
			unless defined($args->{source_map}) && defined($args->{source_x}) && defined($args->{source_y});
		return ({
			current_map => $args->{source_map},
			pos_x       => $args->{source_x},
			pos_y       => $args->{source_y},
			zeny        => $args->{budget},
		}, undef);
	}

	my ($snapshot, $error) = $self->_snapshot();
	return (undef, $error || 'character snapshot is unavailable') unless $snapshot;
	return (undef, 'source map or coordinates are unavailable')
		unless defined($snapshot->{current_map}) && defined($snapshot->{pos_x}) && defined($snapshot->{pos_y});
	return ($snapshot, undef);
}

sub _task_factory {
	my ($self) = @_;
	return $self->{task_factory} if $self->{task_factory};
	require Task::CalcMapRoute;
	return sub { Task::CalcMapRoute->new(@_) };
}

sub _done_status {
	my ($self) = @_;
	return $self->{done_status} if defined $self->{done_status};
	require Task;
	return Task::DONE();
}

sub _running_status {
	my ($self) = @_;
	return $self->{running_status} if defined $self->{running_status};
	require Task;
	return Task::RUNNING();
}

sub _error_name {
	my ($code) = @_;
	return undef unless defined $code;
	return $code if !looks_like_number($code);

	my $load = eval { Task::CalcMapRoute::CANNOT_LOAD_FIELD() };
	return 'CANNOT_LOAD_FIELD' if defined($load) && $code == $load;
	my $calc = eval { Task::CalcMapRoute::CANNOT_CALCULATE_ROUTE() };
	return 'CANNOT_CALCULATE_ROUTE' if defined($calc) && $code == $calc;
	return "TASK_ERROR_$code";
}

sub _has_steps {
	my ($value) = @_;
	return 0 unless defined $value;
	return scalar(@$value) > 0 if ref($value) eq 'ARRAY';
	return scalar(keys %$value) > 0 if ref($value) eq 'HASH';
	return $value ne '' ? 1 : 0;
}

sub parse_route_metadata {
	my ($class, $route) = @_;
	$route = [] unless ref($route) eq 'ARRAY';
	my @steps = grep { ref($_) eq 'HASH' } @$route;
	my $last = @steps ? $steps[-1] : undef;
	return {
		route_hops          => scalar(@steps),
		route_weighted_cost => $last && defined($last->{walk}) ? 0 + $last->{walk} : (@steps ? undef : 0),
		route_zeny          => $last && defined($last->{zeny}) ? 0 + $last->{zeny} : (@steps ? undef : 0),
		route_tickets       => $last && defined($last->{amount_of_tickets_used})
			? 0 + $last->{amount_of_tickets_used} : (@steps ? undef : 0),
		uses_npc           => scalar(grep { _has_steps($_->{steps}) } @steps) ? 1 : 0,
		uses_command       => scalar(grep { $_->{is_command} } @steps) ? 1 : 0,
		uses_airship       => scalar(grep { $_->{is_airship} } @steps) ? 1 : 0,
		uses_save_teleport => scalar(grep { $_->{is_teleportToSaveMap} } @steps) ? 1 : 0,
		uses_warp_item     => scalar(grep { $_->{is_teleportItemWarp} } @steps) ? 1 : 0,
	};
}

sub probe {
	my ($self, %args) = @_;
	my $started = $self->{clock}->();
	my $target_map = $args{map};
	my ($source, $source_error) = $self->_source(\%args);
	my ($source_map, $source_x, $source_y) = $source
		? @{$source}{qw(current_map pos_x pos_y)} : (undef, undef, undef);

	if (!$source) {
		return $self->_result(
			status => 'UNKNOWN', target_map => $target_map,
			error_code => 'SOURCE_UNAVAILABLE', error_message => $source_error,
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}
	if (!defined($target_map) || $target_map eq '') {
		return $self->_result(
			status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, error_code => 'INVALID_TARGET', error_message => 'target map is unavailable',
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}

	# CalcMapRoute accepts a map-only target for cross-map routing, but its
	# same-map branch asks Task::Route to pathfind to missing x/y coordinates.
	# A map-only preflight is already complete when both base map names match.
	if ($source_map eq $target_map) {
		return $self->_result(
			status => 'REACHABLE', source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, route => [], route_string => $source_map,
			route_hops => 0, route_weighted_cost => 0, route_zeny => 0, route_tickets => 0,
			uses_npc => 0, uses_command => 0, uses_airship => 0, uses_save_teleport => 0, uses_warp_item => 0,
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}

	my $wall_timeout_ms = defined($args{wall_timeout_ms}) ? $args{wall_timeout_ms} : $self->{wall_timeout_ms};
	$wall_timeout_ms = 1 if $wall_timeout_ms < 1;
	my $factory;
	my $task;
	my $constructed = eval {
		$factory = $self->_task_factory();
		my %task_args = (
			map => $target_map,
			sourceMap => $source_map,
			sourceX => $source_x,
			sourceY => $source_y,
			maxTime => $self->{task_slice_s},
			suppressDebug => 1,
		);
		$task_args{budget} = $source->{zeny} if defined $source->{zeny};
		$task = $factory->(%task_args);
		$task->activate();
		1;
	};
	if (!$constructed || !$task) {
		my $error = $@ || 'CalcMapRoute construction failed';
		$error =~ s/\s+/ /g;
		return $self->_result(
			status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, error_code => 'TASK_CONSTRUCTION_FAILED', error_message => $error,
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}

	my $done = $self->_done_status();
	my $running = $self->_running_status();
	while ($task->getStatus() != $done) {
		if ($self->_elapsed_ms($started) >= $wall_timeout_ms) {
			eval { $task->stop() if $task->getStatus() == $running };
			return $self->_result(
				status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
				target_map => $target_map, error_code => 'TIMEOUT',
				error_message => "route probe exceeded ${wall_timeout_ms}ms",
				elapsed_ms => $self->_elapsed_ms($started),
			);
		}
		if ($task->getStatus() != $running) {
			return $self->_result(
				status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
				target_map => $target_map, error_code => 'UNEXPECTED_TASK_STATUS',
				error_message => 'CalcMapRoute stopped before completion',
				elapsed_ms => $self->_elapsed_ms($started),
			);
		}
		my $iterated = eval { $task->iterate(); 1 };
		if (!$iterated) {
			my $error = $@ || 'CalcMapRoute iterate failed';
			$error =~ s/\s+/ /g;
			eval { $task->stop() if $task->getStatus() == $running };
			return $self->_result(
				status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
				target_map => $target_map, error_code => 'TASK_EXCEPTION', error_message => $error,
				elapsed_ms => $self->_elapsed_ms($started),
			);
		}
	}

	my $task_error = eval { $task->getError() };
	if ($@) {
		return $self->_result(
			status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, error_code => 'ERROR_READ_FAILED', error_message => $@,
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}
	if ($task_error) {
		my $name = _error_name($task_error->{code});
		my $status = ($name eq 'CANNOT_LOAD_FIELD' || $name eq 'CANNOT_CALCULATE_ROUTE')
			? 'UNREACHABLE' : 'UNKNOWN';
		return $self->_result(
			status => $status, source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, error_code => $name, error_message => $task_error->{message},
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}

	my ($route, $route_string);
	my $read = eval {
		$route = $task->getRoute();
		$route_string = $task->getRouteString();
		1;
	};
	if (!$read || ref($route) ne 'ARRAY' || !@$route) {
		my $error = $@ || 'cross-map route completed without route steps';
		$error =~ s/\s+/ /g;
		return $self->_result(
			status => 'UNKNOWN', source_map => $source_map, source_x => $source_x, source_y => $source_y,
			target_map => $target_map, error_code => 'INVALID_ROUTE_RESULT', error_message => $error,
			elapsed_ms => $self->_elapsed_ms($started),
		);
	}
	my $metadata = $self->parse_route_metadata($route);
	return $self->_result(
		status => 'REACHABLE', source_map => $source_map, source_x => $source_x, source_y => $source_y,
		target_map => $target_map, route => $route, route_string => $route_string,
		%$metadata, elapsed_ms => $self->_elapsed_ms($started),
	);
}

sub first_reachable {
	my ($self, %args) = @_;
	my $candidates = $args{candidates} || [];
	my $max_probes = defined($args{max_probes}) ? $args{max_probes} : 8;
	my $total_timeout_ms = defined($args{total_timeout_ms}) ? $args{total_timeout_ms} : 2000;
	my $per_probe_timeout_ms = defined($args{per_probe_timeout_ms})
		? $args{per_probe_timeout_ms} : $self->{wall_timeout_ms};
	my $started = $self->{clock}->();
	my (%cache, @attempts);
	my $probes_used = 0;

	for my $index (0 .. $#$candidates) {
		my $candidate = $candidates->[$index];
		my $map = $candidate->{target_map};
		my $cached = exists $cache{$map};
		if (!$cached) {
			my $elapsed = $self->_elapsed_ms($started);
			return {
				selected => undef, attempts => \@attempts, probes_used => $probes_used,
				limit_reached => 0, budget_reached => 1, elapsed_ms => $elapsed,
			} if $elapsed >= $total_timeout_ms;
			return {
				selected => undef, attempts => \@attempts, probes_used => $probes_used,
				limit_reached => 1, budget_reached => 0, elapsed_ms => $elapsed,
			} if $probes_used >= $max_probes;

			my $remaining = $total_timeout_ms - $elapsed;
			my $timeout = $per_probe_timeout_ms < $remaining ? $per_probe_timeout_ms : $remaining;
			$cache{$map} = $self->probe(
				map => $map,
				source_map => $args{source_map}, source_x => $args{source_x}, source_y => $args{source_y},
				budget => $args{budget}, wall_timeout_ms => $timeout,
			);
			$probes_used++;
		}
		my $attempt = {
			static_rank => $index + 1,
			candidate => $candidate,
			result => $cache{$map},
			cached => $cached ? 1 : 0,
		};
		push @attempts, $attempt;
		if ($cache{$map}{status} eq 'REACHABLE') {
			return {
				selected => $candidate, selected_result => $cache{$map}, attempts => \@attempts,
				probes_used => $probes_used, limit_reached => 0, budget_reached => 0,
				elapsed_ms => $self->_elapsed_ms($started),
			};
		}
	}

	return {
		selected => undef, attempts => \@attempts, probes_used => $probes_used,
		limit_reached => 0, budget_reached => 0, elapsed_ms => $self->_elapsed_ms($started),
	};
}

1;
