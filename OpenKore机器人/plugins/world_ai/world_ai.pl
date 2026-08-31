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
use WorldAI::Scorer;

our $NAME = 'world_ai';
our $VERSION = '2.0.0';

my $plugin_dir = $Plugins::current_plugin_folder || dirname(__FILE__);
my $index_path = "$plugin_dir/map_index.json";
my $index = WorldAI::Index->new(path => $index_path);
my $scorer = WorldAI::Scorer->new();
my $commands;
my $MAX_TOP_N = 20;

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
	wa_log('[HELP] worldai inspect monster <name|aegis|id>');
	wa_log('[HELP] worldai inspect map <map>');
	wa_log('[HELP] worldai reload');
}

sub print_status {
	wa_log("[STATUS] plugin_version=$VERSION mode=RECOMMEND_ONLY movement_control=OFF combat_control=OFF");
	wa_log('[STATUS] cpu_model=ON_DEMAND background_hooks=0 max_top_n=' . $MAX_TOP_N);
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
