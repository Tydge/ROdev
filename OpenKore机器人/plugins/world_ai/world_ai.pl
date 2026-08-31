package world_ai;

use strict;
use warnings;
no warnings 'redefine';

use Commands;
use File::Basename qw(dirname);
use Globals qw(%maps_lut);
use Log qw(message warning);
use Plugins;
use Time::HiRes qw(time);

BEGIN {
	my $folder = $Plugins::current_plugin_folder || dirname(__FILE__);
	unshift @INC, "$folder/lib";
}
use WorldAI::CharacterSnapshot;
use WorldAI::Index;
use WorldAI::RouteProbe;
use WorldAI::Scorer;

our $NAME = 'world_ai';
our $VERSION = '3.0.0';

my $plugin_dir = $Plugins::current_plugin_folder || dirname(__FILE__);
my $index_path = "$plugin_dir/map_index.json";
my $index = WorldAI::Index->new(path => $index_path);
my $scorer = WorldAI::Scorer->new();
my $route_probe = WorldAI::RouteProbe->new(
	wall_timeout_ms => 1000,
	task_slice_s => 0.03,
);
my $commands;
my $MAX_TOP_N = 20;
my $MAX_ROUTE_PROBES_PER_COMMAND = 8;
my $ROUTE_PROBE_WALL_TIMEOUT_MS = 1000;
my $ROUTE_COMMAND_BUDGET_MS = 2000;

Plugins::register(
	$NAME,
	'Recommendation-only dynamic leveling advisor',
	\&on_unload,
	\&on_unload,
);

$commands = Commands::register(
	['worldai', 'read-only leveling recommendations', \&command_handler],
);

my ($loaded, $load_error) = $index->reload();
if ($loaded) {
	wa_log(sprintf(
		'[PLUGIN] loaded version=%s schema=%s monsters=%d maps=%d mode=RECOMMEND_ONLY',
		$VERSION, $index->schema, $index->monster_count, $index->map_count,
	));
} else {
	wa_warning("[PLUGIN] index unavailable reason=$load_error recommendation=disabled");
}

sub wa_log {
	my ($text, $domain) = @_;
	message "[WORLD_AI] $text\n", ($domain || 'info');
}

sub wa_warning {
	my ($text) = @_;
	warning "[WORLD_AI] $text\n";
}

sub _trim {
	my ($value) = @_;
	$value //= '';
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub _canonical_map {
	my ($map) = @_;
	$map = lc _trim($map);
	$map =~ s/\.rsw$//;
	return undef unless $map =~ /^[a-z0-9_\@]+$/;
	return $map;
}

sub _map_known {
	my ($map) = @_;
	return defined($map) && exists $maps_lut{"$map.rsw"};
}

sub _fmt {
	my ($value) = @_;
	return 'undef' unless defined $value;
	return sprintf('%.1f', $value);
}

sub _snapshot {
	my ($snapshot, $error) = WorldAI::CharacterSnapshot::capture();
	return ($snapshot, $error);
}

sub _ensure_ready {
	unless ($index->loaded) {
		wa_warning('[ERROR] recommendation unavailable: index is not loaded');
		return;
	}
	return 1;
}

sub command_handler {
	my (undef, $args) = @_;
	$args = _trim($args);

	my $ok = eval {
		if ($args eq '' || $args eq 'help') {
			print_help();
		} elsif ($args eq 'status') {
			print_status();
		} elsif ($args =~ /^top(?:\s+(\d+))?$/i) {
			print_top(defined($1) ? int($1) : 5);
		} elsif ($args =~ /^route\s+(\S+)$/i) {
			print_route($1);
		} elsif ($args =~ /^recommend\s+reachable$/i) {
			print_reachable_recommendation();
		} elsif ($args =~ /^recommend$/i) {
			print_recommendation();
		} elsif ($args =~ /^inspect\s+monster\s+(.+)$/i) {
			inspect_monster($1);
		} elsif ($args =~ /^inspect\s+map\s+(\S+)$/i) {
			inspect_map($1);
		} elsif ($args =~ /^reload$/i) {
			reload_index();
		} else {
			wa_warning("[ERROR] unknown command: $args");
			print_help();
		}
		1;
	};
	if (!$ok) {
		my $error = $@ || 'unknown command failure';
		$error =~ s/\s+/ /g;
		wa_warning("[ERROR] command failed safely: $error");
	}
}

sub print_help {
	wa_log('[HELP] worldai status');
	wa_log('[HELP] worldai top [N]');
	wa_log('[HELP] worldai recommend');
	wa_log('[HELP] worldai route <map>');
	wa_log('[HELP] worldai recommend reachable');
	wa_log('[HELP] worldai inspect monster <name|aegis|id>');
	wa_log('[HELP] worldai inspect map <map>');
	wa_log('[HELP] worldai reload');
}

sub print_status {
	wa_log("[STATUS] plugin_version=$VERSION mode=RECOMMEND_ONLY movement_control=OFF combat_control=OFF");
	wa_log(sprintf(
		'[STATUS] cpu_model=ON_DEMAND background_hooks=0 max_top_n=%d route_engine=Task::CalcMapRoute route_probe_timeout_ms=%d route_command_budget_ms=%d max_route_probes=%d',
		$MAX_TOP_N, $ROUTE_PROBE_WALL_TIMEOUT_MS, $ROUTE_COMMAND_BUDGET_MS, $MAX_ROUTE_PROBES_PER_COMMAND,
	));
	if ($index->loaded) {
		wa_log(sprintf(
			'[STATUS] index=loaded schema=%s monsters=%d maps=%d candidate_pairs=%d',
			$index->schema, $index->monster_count, $index->map_count, $index->pair_count,
		));
	} else {
		wa_warning('[STATUS] index=unavailable reason=' . ($index->last_error // 'unknown'));
	}

	my ($snapshot, $error) = _snapshot();
	if (!$snapshot) {
		wa_warning("[STATUS] character=unavailable reason=$error");
		return;
	}
	wa_log(sprintf(
		'[CHARACTER] base=%s job=%s class=%s map=%s hp=%s/%s sp=%s/%s atk=%s def=%s hit=%s flee=%s',
		map { defined($_) ? $_ : 'undef' } @{$snapshot}{qw(base_level job_level job_name current_map hp hp_max sp sp_max attack_total defense_total hit flee)}
	));
}

sub _candidate_result {
	my ($snapshot, $monster, $map, $spawn_count, $profiles) = @_;
	my $map_spawns = $index->map_spawns($map) || {};
	$profiles->{$map} ||= $scorer->prepare_map_profile(
		$snapshot,
		$map,
		$map_spawns,
		sub { $index->monster($_[0]) },
	);
	my $scored = $scorer->score_candidate(
		$snapshot, $monster, $map, $spawn_count, $profiles->{$map},
	);
	return {
		%{$scored},
		monster_id   => 0 + $monster->{id},
		monster_name => $monster->{name},
		target_map   => $map,
		spawn_count  => 0 + $spawn_count,
		monster_level => 0 + $monster->{level},
		base_exp     => 0 + ($monster->{base_exp} || 0),
		job_exp      => 0 + ($monster->{job_exp} || 0),
		map_known    => _map_known($map) ? 1 : 0,
	};
}

sub _all_candidates {
	my ($snapshot) = @_;
	my @results;
	my %profiles;
	for my $id ($index->monster_ids) {
		my $monster = $index->monster($id);
		for my $map (sort keys %{$monster->{maps}}) {
			next unless _map_known($map);
			my $result = _candidate_result(
				$snapshot, $monster, $map, $monster->{maps}{$map}, \%profiles,
			);
			push @results, $result if $result->{allowed};
		}
	}
	@results = sort {
		$b->{score} <=> $a->{score}
			|| $a->{monster_id} <=> $b->{monster_id}
			|| $a->{target_map} cmp $b->{target_map}
	} @results;
	return \@results;
}

sub _calculate_ranked {
	return unless _ensure_ready();
	my ($snapshot, $error) = _snapshot();
	if (!$snapshot) {
		wa_warning("[ERROR] character snapshot unavailable reason=$error");
		return;
	}

	my $started = time;
	my $results = _all_candidates($snapshot);
	my $elapsed_ms = (time - $started) * 1000;
	return ($snapshot, $results, $elapsed_ms);
}

sub _print_breakdown {
	my ($result) = @_;
	my $b = $result->{breakdown};
	wa_log(sprintf(
		'  breakdown: +level_fit=%s +exp_value=%s +spawn_count_score=%s -kill_cost=%s -target_risk=%s -map_risk=%s',
		map { _fmt($b->{$_}) } qw(level_fit exp_value spawn_count_score kill_cost target_risk map_risk)
	));
}

sub _print_compact_result {
	my ($rank, $result) = @_;
	wa_log(sprintf(
		'#%d %s (%d) @ %s score=%s risk=%s spawn=%d level=%d exp=%d+%d route=%s travel_cost=undef',
		$rank, $result->{monster_name}, $result->{monster_id}, $result->{target_map},
		_fmt($result->{score}), $result->{risk}, $result->{spawn_count},
		$result->{monster_level}, $result->{base_exp}, $result->{job_exp},
		$result->{route_reachability},
	));
	_print_breakdown($result);
	wa_log('  reasons: ' . (@{$result->{reasons}} ? join('; ', @{$result->{reasons}}) : 'balanced static score'));
}

sub print_top {
	my ($requested) = @_;
	my $n = $requested;
	$n = 1 if $n < 1;
	if ($n > $MAX_TOP_N) {
		wa_warning("[TOP] requested=$requested capped=$MAX_TOP_N");
		$n = $MAX_TOP_N;
	}

	my ($snapshot, $results, $elapsed_ms) = _calculate_ranked();
	return unless $results;
	my $shown = @$results < $n ? scalar(@$results) : $n;
	wa_log(sprintf('[TOP] valid_candidates=%d shown=%d elapsed_ms=%.1f', scalar(@$results), $shown, $elapsed_ms));
	for my $i (0 .. $shown - 1) {
		_print_compact_result($i + 1, $results->[$i]);
	}
}

sub print_recommendation {
	my (undef, $results, $elapsed_ms) = _calculate_ranked();
	return unless $results;
	if (!@$results) {
		wa_warning('[RECOMMEND] no allowed candidate');
		return;
	}
	wa_log(sprintf('[RECOMMEND] elapsed_ms=%.1f', $elapsed_ms));
	_print_compact_result(1, $results->[0]);
	wa_log('  estimated_hits=' . _fmt($results->[0]{estimated_hits}));
}

sub _route_value {
	my ($value) = @_;
	return defined($value) ? $value : 'undef';
}

sub _print_route_result {
	my ($result, %args) = @_;
	my $prefix = $args{prefix} || 'ROUTE';
	wa_log(sprintf(
		'[%s] source=%s (%s,%s) target=%s status=%s engine=%s elapsed_ms=%s',
		$prefix,
		_route_value($result->{source_map}), _route_value($result->{source_x}), _route_value($result->{source_y}),
		_route_value($result->{target_map}), $result->{status}, $result->{engine}, _route_value($result->{elapsed_ms}),
	));
	if ($result->{status} eq 'REACHABLE') {
		wa_log(sprintf(
			'[%s] hops=%s weighted_cost=%s zeny=%s tickets=%s npc=%s command=%s airship=%s save_teleport=%s warp_item=%s',
			$prefix,
			map { _route_value($result->{$_}) }
				qw(route_hops route_weighted_cost route_zeny route_tickets uses_npc uses_command uses_airship uses_save_teleport uses_warp_item),
		));
		wa_log("[$prefix] route=" . _route_value($result->{route_string}));
	} else {
		wa_warning(sprintf(
			'[%s] error=%s message=%s',
			$prefix, _route_value($result->{error_code}), _route_value($result->{error_message}),
		));
	}
}

sub print_route {
	my ($requested_map) = @_;
	my $map = _canonical_map($requested_map);
	if (!$map) {
		wa_warning('[ROUTE] invalid map name');
		return;
	}
	my ($snapshot, $error) = _snapshot();
	if (!$snapshot) {
		wa_warning("[ROUTE] character snapshot unavailable reason=$error");
		return;
	}
	my $result = $route_probe->probe(
		map => $map,
		source_map => $snapshot->{current_map}, source_x => $snapshot->{pos_x}, source_y => $snapshot->{pos_y},
		budget => $snapshot->{zeny}, wall_timeout_ms => $ROUTE_PROBE_WALL_TIMEOUT_MS,
	);
	_print_route_result($result);
	wa_log('[ROUTE] recommendation_only=yes movement_control=OFF combat_control=OFF');
}

sub print_reachable_recommendation {
	my ($snapshot, $results, $score_elapsed_ms) = _calculate_ranked();
	return unless $results;
	if (!@$results) {
		wa_warning('[RECOMMEND_REACHABLE] no allowed candidate');
		return;
	}
	unless (defined($snapshot->{current_map}) && defined($snapshot->{pos_x}) && defined($snapshot->{pos_y})) {
		wa_warning('[RECOMMEND_REACHABLE] source map or coordinates are unavailable');
		return;
	}

	my $validated = $route_probe->first_reachable(
		candidates => $results,
		source_map => $snapshot->{current_map}, source_x => $snapshot->{pos_x}, source_y => $snapshot->{pos_y},
		budget => $snapshot->{zeny},
		max_probes => $MAX_ROUTE_PROBES_PER_COMMAND,
		per_probe_timeout_ms => $ROUTE_PROBE_WALL_TIMEOUT_MS,
		total_timeout_ms => $ROUTE_COMMAND_BUDGET_MS,
	);
	wa_log(sprintf(
		'[RECOMMEND_REACHABLE] static_score_ms=%.1f route_elapsed_ms=%s probes=%d',
		$score_elapsed_ms, _route_value($validated->{elapsed_ms}), $validated->{probes_used},
	));
	for my $attempt (@{$validated->{attempts}}) {
		next if $attempt->{cached};
		my $candidate = $attempt->{candidate};
		my $route = $attempt->{result};
		wa_log(sprintf(
			'[VALIDATE] static_rank=%d %s (%d) @ %s score=%s risk=%s route=%s cached=%s action=%s',
			$attempt->{static_rank}, $candidate->{monster_name}, $candidate->{monster_id}, $candidate->{target_map},
			_fmt($candidate->{score}), $candidate->{risk}, $route->{status}, $attempt->{cached} ? 'yes' : 'no',
			$route->{status} eq 'REACHABLE' ? 'SELECTED' : $route->{status} eq 'UNREACHABLE' ? 'SKIPPED' : 'DEFERRED',
		));
		wa_warning(sprintf('[VALIDATE] map=%s error=%s', $candidate->{target_map}, _route_value($route->{error_code})))
			if $route->{status} ne 'REACHABLE';
	}

	wa_warning('[RECOMMEND_REACHABLE] route_probe_limit_reached') if $validated->{limit_reached};
	wa_warning('[RECOMMEND_REACHABLE] route_command_budget_reached') if $validated->{budget_reached};
	if ($validated->{selected}) {
		my $selected = $validated->{selected};
		my $selected_rank = @{$validated->{attempts}}
			? $validated->{attempts}[-1]{static_rank} : 1;
		wa_log(sprintf(
			'[SELECTED] %s (%d) @ %s score=%s risk=%s static_rank=%d',
			$selected->{monster_name}, $selected->{monster_id}, $selected->{target_map},
			_fmt($selected->{score}), $selected->{risk}, $selected_rank,
		));
		_print_route_result($validated->{selected_result}, prefix => 'SELECTED_ROUTE');
	} else {
		wa_warning('[RECOMMEND_REACHABLE] no definitely reachable candidate within limits');
	}
	wa_log('[RECOMMEND_REACHABLE] recommendation_only=yes movement_control=OFF combat_control=OFF');
}

sub inspect_monster {
	my ($query) = @_;
	return unless _ensure_ready();
	my @matches = $index->find_monsters($query);
	if (!@matches) {
		wa_warning("[INSPECT_MONSTER] not found query=" . _trim($query));
		return;
	}
	if (@matches > 1) {
		wa_warning('[INSPECT_MONSTER] ambiguous name; use ID or AegisName');
		for my $monster (@matches) {
			wa_log(sprintf('  id=%d name=%s aegis=%s', @{$monster}{qw(id name aegis_name)}));
		}
		return;
	}

	my $monster = $matches[0];
	wa_log(sprintf(
		'[MONSTER] id=%d name=%s aegis=%s level=%d hp=%d atk=%d-%d def=%d mdef=%d exp=%d+%d mvp=%s',
		$monster->{id}, $monster->{name}, $monster->{aegis_name}, $monster->{level},
		$monster->{hp}, $monster->{attack}, $monster->{attack2}, $monster->{defense},
		$monster->{magic_defense}, $monster->{base_exp}, $monster->{job_exp},
		$monster->{is_mvp} ? 'yes' : 'no',
	));

	my ($snapshot, $snapshot_error) = _snapshot();
	my %profiles;
	for my $map (sort keys %{$monster->{maps}}) {
		my $known = _map_known($map);
		if (!$snapshot) {
			wa_log(sprintf('  map=%s spawn=%d known=%s score=unavailable', $map, $monster->{maps}{$map}, $known ? 'yes' : 'no'));
			next;
		}
		if (!$known) {
			wa_log(sprintf('  map=%s spawn=%d known=no allowed=no reason=unknown_to_maps_lut', $map, $monster->{maps}{$map}));
			next;
		}
		my $result = _candidate_result($snapshot, $monster, $map, $monster->{maps}{$map}, \%profiles);
		wa_log(sprintf(
			'  map=%s spawn=%d allowed=%s score=%s risk=%s reasons=%s',
			$map, $monster->{maps}{$map}, $result->{allowed} ? 'yes' : 'no',
			_fmt($result->{score}), $result->{risk}, join('; ', @{$result->{reasons}}),
		));
	}
	wa_warning("[INSPECT_MONSTER] live score unavailable reason=$snapshot_error") unless $snapshot;
}

sub inspect_map {
	my ($requested_map) = @_;
	return unless _ensure_ready();
	my $map = _canonical_map($requested_map);
	if (!$map) {
		wa_warning('[INSPECT_MAP] invalid map name');
		return;
	}
	my $spawns = $index->map_spawns($map);
	if (!$spawns) {
		wa_warning("[INSPECT_MAP] map not present in static index map=$map");
		return;
	}
	wa_log(sprintf('[MAP] name=%s known=%s route_reachability=UNVERIFIED monster_kinds=%d',
		$map, _map_known($map) ? 'yes' : 'no', scalar(keys %{$spawns})));

	my ($snapshot, $snapshot_error) = _snapshot();
	my $profile = $snapshot ? $scorer->prepare_map_profile(
		$snapshot, $map, $spawns, sub { $index->monster($_[0]) },
	) : undef;
	for my $id (sort { $a <=> $b } keys %{$spawns}) {
		my $monster = $index->monster($id);
		my $weighted = $profile ? $profile->{contributions}{$id}{weighted} : undef;
		wa_log(sprintf(
			'  id=%d name=%s level=%d spawn=%d danger_contribution=%s',
			$id, $monster->{name}, $monster->{level}, $spawns->{$id}, _fmt($weighted),
		));
	}
	if ($profile) {
		wa_log('[MAP] aggregate_danger=' . _fmt($profile->{total}));
	} else {
		wa_warning("[INSPECT_MAP] live danger unavailable reason=$snapshot_error");
	}
}

sub reload_index {
	my ($ok, $error) = $index->reload();
	if ($ok) {
		wa_log(sprintf('[RELOAD] success schema=%s monsters=%d maps=%d',
			$index->schema, $index->monster_count, $index->map_count));
	} else {
		wa_warning("[RELOAD] failed reason=$error previous_index_retained=" . ($index->loaded ? 'yes' : 'no'));
	}
}

sub on_unload {
	Commands::unregister($commands) if $commands;
	wa_log('[PLUGIN] unloaded side_effects=none');
}

1;
