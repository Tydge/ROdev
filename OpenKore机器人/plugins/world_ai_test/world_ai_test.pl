package world_ai_test;

use strict;
use warnings;
no warnings 'redefine';

use AI;
use Commands;
use Globals qw($char $field $net $monstersList %config %maps_lut %mon_control);
use Log qw(message warning);
use Misc qw(configModify);
use Network;
use Plugins;
use Scalar::Util qw(blessed);
use Task;
use Time::HiRes qw(time);

our $NAME = 'world_ai_test';

my %TEST_MONSTER_MAPS = (
	poring => {
		name       => 'Poring',
		candidates => [
			{ map => 'prt_fild08', spawn => 70 },
		],
	},
	rocker => {
		name       => 'Rocker',
		candidates => [
			{ map => 'prt_fild07', spawn => 80 },
			{ map => 'prt_fild04', spawn => 70 },
		],
	},
);

my %test = (
	state             => 'IDLE',
	mode              => '',
	start_map         => '',
	target_map        => '',
	target_monster    => '',
	start_time        => 0,
	hunt_start_time   => 0,
	timeout           => 0,
	last_map          => '',
	last_error        => '',
	attack_started    => 0,
	target_seen       => 0,
	success_level     => '',
);

my $route_task;
my $commands;
my $hooks;
my $lock_map_overridden = 0;
my $saved_lock_map;
my $monster_override_key;
my $monster_override_existed = 0;
my $saved_monster_control;

Plugins::register(
	$NAME,
	'Minimal native MapRoute and monster-to-map experiment',
	\&on_unload,
	\&on_unload,
);

$commands = Commands::register(
	['worldtest', 'native navigation and hunt experiment', \&command_handler],
);

$hooks = Plugins::addHooks(
	['AI_pre',      \&on_ai_pre],
	['attack_start', \&on_attack_start],
	['target_died',  \&on_target_died],
);

sub wt_log {
	my ($message_text, $domain) = @_;
	$domain ||= 'info';
	message "[WORLDTEST]$message_text\n", $domain;
}

sub wt_warning {
	my ($message_text) = @_;
	warning "[WORLDTEST]$message_text\n";
}

sub current_map {
	return '' unless $field;
	return $field->baseName // '';
}

sub elapsed {
	return '0.0' unless $test{start_time};
	return sprintf('%.1f', time - ($test{start_time} || time));
}

sub ai_action {
	return AI::action() // 'none';
}

sub is_in_game {
	return $net && $net->getState() == Network::IN_GAME && $char && $field;
}

sub valid_map {
	my ($map) = @_;
	return 0 unless defined $map && $map =~ /^[A-Za-z0-9_\@]+$/;
	return exists $maps_lut{"$map.rsw"};
}

sub normalize_monster {
	my ($name) = @_;
	$name //= '';
	$name =~ s/^\s+|\s+$//g;
	return lc $name;
}

sub command_handler {
	my (undef, $args) = @_;
	$args //= '';
	$args =~ s/^\s+|\s+$//g;
	my ($subcommand, $value) = split /\s+/, $args, 2;
	$subcommand = lc($subcommand // '');
	$value //= '';
	$value =~ s/^\s+|\s+$//g;

	if ($subcommand eq 'nav') {
		start_navigation_command($value);
	} elsif ($subcommand eq 'hunt') {
		start_hunt_command($value);
	} elsif ($subcommand eq 'status') {
		print_status();
	} elsif ($subcommand eq 'stop') {
		stop_test('user_stop');
	} else {
		wt_log('[HELP] worldtest nav <map>');
		wt_log('[HELP] worldtest hunt <monster>');
		wt_log('[HELP] worldtest status');
		wt_log('[HELP] worldtest stop');
	}
}

sub start_navigation_command {
	my ($target_map) = @_;
	unless (is_in_game()) {
		wt_warning('[NAV] FAILED reason=not_in_game');
		return;
	}
	unless (valid_map($target_map)) {
		wt_warning("[NAV] FAILED reason=invalid_or_unknown_map target=$target_map");
		return;
	}

	prepare_new_test();
	start_navigation('NAV', $target_map, '');
}

sub start_hunt_command {
	my ($requested_monster) = @_;
	unless (is_in_game()) {
		wt_warning('[HUNT] FAILED reason=not_in_game');
		return;
	}

	my $key = normalize_monster($requested_monster);
	my $entry = $TEST_MONSTER_MAPS{$key};
	unless ($entry) {
		wt_warning("[HUNT] FAILED monster=$requested_monster reason=no_candidate_map");
		return;
	}

	prepare_new_test();
	$test{state} = 'SELECTING_MAP';
	$test{mode} = 'HUNT';
	$test{target_monster} = $entry->{name};
	wt_log("[HUNT] requested_monster=$entry->{name}");

	my @candidates = sort {
		$b->{spawn} <=> $a->{spawn} || $a->{map} cmp $b->{map}
	} @{$entry->{candidates}};
	for my $candidate (@candidates) {
		wt_log("[HUNT] candidate_map=$candidate->{map} spawn=$candidate->{spawn}");
	}

	my $selected = $candidates[0];
	unless ($selected && valid_map($selected->{map})) {
		fail_test('no_valid_candidate_map');
		return;
	}

	wt_log("[HUNT] selected_map=$selected->{map}");
	apply_hunt_overrides($entry->{name}, $selected->{map});
	start_navigation('HUNT', $selected->{map}, $entry->{name});
}

sub prepare_new_test {
	if ($test{state} ne 'IDLE') {
		cleanup_runtime_changes(1);
	}
	reset_state();
}

sub start_navigation {
	my ($mode, $target_map, $monster) = @_;
	my $nav_prefix = $mode eq 'NAV' ? '[NAV]' : "[$mode][NAV]";
	my $start_map = current_map();
	my $is_short =
		($start_map eq 'prt_fild08' && $target_map eq 'prt_fild07') ||
		($start_map eq 'prt_fild07' && $target_map eq 'prt_fild08');

	$test{state} = 'NAVIGATING';
	$test{mode} = $mode;
	$test{start_map} = $start_map;
	$test{target_map} = $target_map;
	$test{target_monster} = $monster if $monster;
	$test{start_time} = time;
	$test{timeout} = $is_short ? 120 : 300;
	$test{last_map} = $start_map;
	$test{last_error} = '';
	$route_task = undef;

	wt_log("$nav_prefix start");
	wt_log("$nav_prefix from=$start_map");
	wt_log("$nav_prefix target=$target_map timeout=$test{timeout}s");

	Commands::run("move $target_map");
	if ((AI::action() // '') eq 'route') {
		my $candidate = AI::args(0);
		$route_task = $candidate
			if blessed($candidate) && $candidate->isa('Task::MapRoute');
	}

	unless ($route_task) {
		fail_test('maproute_not_created');
		return;
	}

	wt_log("$nav_prefix api=Commands::run task=Task::MapRoute");
	check_map_progress();
}

sub apply_hunt_overrides {
	my ($monster, $target_map) = @_;

	$saved_lock_map = $config{lockMap};
	configModify('lockMap', $target_map, autoCreate => 0, silent => 1);
	$lock_map_overridden = 1;
	wt_log("[HUNT] lockMap=$target_map previous=" . ($saved_lock_map // ''));

	$monster_override_key = lc $monster;
	$monster_override_existed = exists $mon_control{$monster_override_key};
	$saved_monster_control = $monster_override_existed
		? { %{$mon_control{$monster_override_key}} }
		: undef;

	my $fallback = $mon_control{$monster_override_key}
		|| $mon_control{all}
		|| {};
	$mon_control{$monster_override_key} = {
		%{$fallback},
		attack_auto => 1,
	};
	wt_log("[HUNT] mon_control_override monster=$monster attack=1 persistence=memory_only");
}

sub check_map_progress {
	return unless $test{state} eq 'NAVIGATING';
	my $map = current_map();
	return unless $map;

	if ($test{last_map} && $map ne $test{last_map}) {
		my $nav_prefix = $test{mode} eq 'NAV' ? '[NAV]' : "[$test{mode}][NAV]";
		wt_log("$nav_prefix map_changed $test{last_map} -> $map");
	}
	$test{last_map} = $map;

	if ($map eq $test{target_map}) {
		on_arrival();
	}
}

sub on_arrival {
	return unless $test{state} eq 'NAVIGATING';
	my $mode = $test{mode};

	if ($mode eq 'NAV') {
		$test{state} = 'SUCCESS';
		$test{success_level} = 'MAP_ARRIVAL';
		wt_log("[NAV] SUCCESS target=$test{target_map} elapsed=" . elapsed() . 's', 'success');
		return;
	}

	$test{state} = 'ARRIVED';
	wt_log("[HUNT] arrived map=$test{target_map} elapsed=" . elapsed() . 's');
	$test{state} = 'HUNTING';
	$test{hunt_start_time} = time;
	wt_log("[HUNT] state=HUNTING monster=$test{target_monster}");
	check_target_seen();
}

sub check_target_seen {
	return unless $test{state} eq 'HUNTING';
	return if $test{target_seen};
	return unless $monstersList;

	for my $monster (@{$monstersList}) {
		next unless lc($monster->name // '') eq lc($test{target_monster});
		$test{target_seen} = 1;
		wt_log("[HUNT] target_seen name=$test{target_monster}");
		last;
	}
}

sub on_attack_start {
	my (undef, $args) = @_;
	return unless $test{state} eq 'HUNTING';
	return unless $monstersList && $args->{ID};
	my $monster = $monstersList->getByID($args->{ID});
	return unless $monster;
	return unless lc($monster->name // '') eq lc($test{target_monster});

	$test{target_seen} = 1;
	return if $test{attack_started};
	$test{attack_started} = 1;
	$test{success_level} = 'ATTACK_STARTED';
	wt_log("[HUNT] target_attack_started name=$test{target_monster}", 'success');
}

sub on_target_died {
	my (undef, $args) = @_;
	return unless $test{state} eq 'HUNTING';
	my $monster = $args->{monster};
	return unless $monster;
	return unless lc($monster->name // '') eq lc($test{target_monster});
	return unless ($monster->{dmgFromYou} // 0) > 0;

	$test{state} = 'SUCCESS';
	$test{success_level} = 'KILL_CONFIRMED';
	wt_log(
		"[HUNT] SUCCESS monster=$test{target_monster} map=" . current_map() .
		" evidence=KILL_CONFIRMED elapsed=" . elapsed() . 's',
		'success',
	);
}

sub on_ai_pre {
	return if $test{state} eq 'IDLE';
	check_map_progress();
	check_target_seen();

	if ($test{state} eq 'NAVIGATING' && $route_task) {
		my $status = $route_task->getStatus();
		if ($status == Task::DONE && current_map() ne $test{target_map}) {
			my $route_error = $route_task->getError();
			if ($route_error) {
				my $message_text = $route_error->{message} // 'unknown';
				$message_text =~ s/\s+/ /g;
				fail_test("route_failed code=$route_error->{code} message=$message_text");
			} else {
				fail_test('route_ended_before_target');
			}
			return;
		} elsif ($status == Task::STOPPED && current_map() ne $test{target_map}) {
			fail_test('route_stopped');
			return;
		}
	}

	if ($test{state} eq 'NAVIGATING' && time - $test{start_time} > $test{timeout}) {
		fail_test('route_timeout');
		return;
	}

	if ($test{state} eq 'HUNTING' && time - $test{hunt_start_time} > 300) {
		if ($test{attack_started}) {
			$test{state} = 'SUCCESS';
			$test{success_level} = 'ATTACK_STARTED';
			wt_log(
				"[HUNT] SUCCESS monster=$test{target_monster} map=" . current_map() .
				' evidence=ATTACK_STARTED kill_confirmation=timeout',
				'success',
			);
		} else {
			fail_test('hunt_timeout');
		}
	}
}

sub fail_test {
	my ($reason) = @_;
	$test{state} = 'FAILED';
	$test{last_error} = $reason;
	wt_warning(
		"[$test{mode}] FAILED reason=$reason current_map=" . current_map() .
		" target_map=$test{target_map} elapsed=" . elapsed() .
		's ai_action=' . ai_action()
	);
	cleanup_runtime_changes(1);
}

sub print_status {
	wt_log(
		"[STATUS] state=$test{state} mode=" . ($test{mode} || 'none') .
		" current_map=" . (current_map() || 'unknown') .
		" start_map=" . ($test{start_map} || 'none') .
		" target_map=" . ($test{target_map} || 'none') .
		" target_monster=" . ($test{target_monster} || 'none') .
		" elapsed=" . elapsed() .
		"s ai_action=" . ai_action() .
		" success_level=" . ($test{success_level} || 'none') .
		" last_error=" . ($test{last_error} || 'none')
	);
}

sub stop_test {
	my ($reason) = @_;
	if ($test{state} eq 'IDLE') {
		wt_log('[STOP] no_active_test');
		return;
	}

	my $previous_state = $test{state};
	cleanup_runtime_changes(1);
	wt_log("[STOP] reason=$reason previous_state=$previous_state restored=1");
	reset_state();
}

sub cleanup_runtime_changes {
	my ($stop_movement) = @_;
	Commands::run('move stop') if $stop_movement && is_in_game();
	$route_task = undef;

	if ($lock_map_overridden) {
		configModify('lockMap', $saved_lock_map, autoCreate => 0, silent => 1);
		$lock_map_overridden = 0;
		$saved_lock_map = undef;
	}

	if (defined $monster_override_key) {
		if ($monster_override_existed) {
			$mon_control{$monster_override_key} = $saved_monster_control;
		} else {
			delete $mon_control{$monster_override_key};
		}
		$monster_override_key = undef;
		$monster_override_existed = 0;
		$saved_monster_control = undef;
	}
}

sub reset_state {
	%test = (
		state             => 'IDLE',
		mode              => '',
		start_map         => '',
		target_map        => '',
		target_monster    => '',
		start_time        => 0,
		hunt_start_time   => 0,
		timeout           => 0,
		last_map          => '',
		last_error        => '',
		attack_started    => 0,
		target_seen       => 0,
		success_level     => '',
	);
}

sub on_unload {
	cleanup_runtime_changes(1);
	Commands::unregister($commands) if $commands;
	Plugins::delHooks($hooks) if $hooks;
	wt_log('[PLUGIN] unloaded restored=1');
}

1;
