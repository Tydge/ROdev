package world_ai;

use strict;
use warnings;
no warnings 'redefine';

use AI;
use Commands;
use File::Basename qw(dirname);
use Globals qw($char $field $net %config %jobs_lut %maps_lut %mon_control);
use Log qw(message warning);
use Network;
use Plugins;
use Scalar::Util qw(blessed refaddr);
use Skill;
use Task;
use Time::HiRes qw(time);

BEGIN {
	my $folder = $Plugins::current_plugin_folder || dirname(__FILE__);
	unshift @INC, "$folder/lib";
}
use WorldAI::CharacterSnapshot;
use WorldAI::CombatPolicy;
use WorldAI::CombatRuntimeOverride;
use WorldAI::ExecutionPolicy;
use WorldAI::Index;
use WorldAI::RouteProbe;
use WorldAI::RuntimeOverride;
use WorldAI::Scorer;

our $NAME = 'world_ai';
our $VERSION = '3.6.0';

my $plugin_dir = $Plugins::current_plugin_folder || dirname(__FILE__);
my $index_path = "$plugin_dir/map_index.json";
my $index = WorldAI::Index->new(path => $index_path);
my $scorer = WorldAI::Scorer->new();
my $route_probe = WorldAI::RouteProbe->new(
	wall_timeout_ms => 1000,
	task_slice_s => 0.03,
);
my $EXEC_MAX_HOPS = WorldAI::ExecutionPolicy->normalize_max_hops($config{world_ai_exec_max_hops});
unless (defined $EXEC_MAX_HOPS) {
	$EXEC_MAX_HOPS = 6;
	my $raw = defined($config{world_ai_exec_max_hops}) ? $config{world_ai_exec_max_hops} : '';
	$raw =~ s/\s+/ /g;
	wa_warning("[PLUGIN] invalid world_ai_exec_max_hops='$raw' (expected 1..10); falling back to 6");
}
my $execution_policy = WorldAI::ExecutionPolicy->new(
	allow_npc => 0,
	max_hops  => $EXEC_MAX_HOPS,
);
my $runtime_override = WorldAI::RuntimeOverride->new(
	config => \%config,
	mon_control => \%mon_control,
);
my $combat_policy = WorldAI::CombatPolicy->new();
my $combat_runtime_override = WorldAI::CombatRuntimeOverride->new(config => \%config);
my $commands;
my $hooks;
my $MAX_TOP_N = 20;
my $MAX_ROUTE_PROBES_PER_COMMAND = 8;
my $ROUTE_PROBE_WALL_TIMEOUT_MS = 1000;
my $ROUTE_COMMAND_BUDGET_MS = 2000;
my $EXEC_SAFE_WAIT_SECONDS = 30;
my $EXEC_MOVE_TIMEOUT_SECONDS = 900;
my %execution;
my $buy_guard_last_warn = 0;
my $recovery_gate_last_warn = 0;
my %recovery_mode = (active => 0, saved => {});   # 濒死兜底：暂停原生战斗+坐地回血
my $auto_execute_last_attempt = time;
my $auto_execute_backoff_s = 15;
my $AUTO_EXECUTE_MAX_BACKOFF_S = 300;
my $MAX_ZERO_KILL_DEATHS = 2;
my $MAX_LOW_PROGRESS_DEATHS = 2;
my $MAX_NO_KILL_ATTACKS = 3;
my $MAX_NO_KILL_ELAPSED_S = 180;
my $TARGET_FAILURE_COOLDOWN_S = 1800;
my $GLOBAL_MONSTER_COOLDOWN_S = 3600;   # 跨图换怪冷却：同一怪累计死亡过多则全局弃选 1 小时
my $MAX_GLOBAL_MONSTER_DEATHS = 2;      # 累计死亡达到此阈值即触发全局换怪
my %target_cooldown;                    # key: "monster_id@map"（单图）
my %monster_cooldown;                   # key: monster_id（跨图全局）
my %monster_stats;                      # monster_id -> { kills => N, deaths => M }（会话累计）

Plugins::register(
	$NAME,
	'Controlled dynamic leveling advisor and executor',
	\&on_unload,
	\&on_unload,
);

$commands = Commands::register(
	['worldai', 'leveling recommendations and controlled execution', \&command_handler],
);

$hooks = Plugins::addHooks(
	['AI_pre',               \&on_ai_pre],
	['attack_start',         \&on_attack_start],
	['target_died',          \&on_target_died],
	['packet_charSkills',    \&on_skill_update],
	['AI_buy_auto_needitem', \&on_buy_auto_needitem],
);

_reset_execution();

my ($loaded, $load_error) = $index->reload();
if ($loaded) {
	wa_log(sprintf(
		'[PLUGIN] loaded version=%s schema=%s monsters=%d maps=%d mode=CONTROLLED_EXECUTION',
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
		} elsif ($args =~ /^execute$/i) {
			start_execution();
		} elsif ($args =~ /^exec\s+status$/i) {
			print_execution_status();
		} elsif ($args =~ /^exec\s+stop$/i) {
			stop_execution('user_stop');
		} elsif ($args =~ /^combat\s+inspect$/i) {
			print_combat_inspect();
		} elsif ($args =~ /^recommend$/i) {
			print_recommendation();
		} elsif ($args =~ /^inspect\s+monster\s+(.+)$/i) {
			inspect_monster($1);
		} elsif ($args =~ /^inspect\s+map\s+(\S+)$/i) {
			inspect_map($1);
		} elsif ($args =~ /^autoexecute\s+(on|off)$/i) {
			my $enable = lc($1) eq 'on' ? 1 : 0;
			$config{world_ai_auto_execute} = $enable;
			wa_log('[AUTO_EXEC] auto_execute=' . ($enable ? 'on' : 'off') .
				' (runtime only; add "world_ai_auto_execute 1" to config.txt to persist)');
		} elsif ($args =~ /^autoexecute$/i) {
			wa_log('[AUTO_EXEC] auto_execute=' . (_auto_execute_enabled() ? 'on' : 'off'));
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
	wa_log('[HELP] worldai execute');
	wa_log('[HELP] worldai exec status');
	wa_log('[HELP] worldai exec stop');
	wa_log('[HELP] worldai combat inspect');
	wa_log('[HELP] worldai autoexecute [on|off]');
	wa_log('[HELP] worldai inspect monster <name|aegis|id>');
	wa_log('[HELP] worldai inspect map <map>');
	wa_log('[HELP] worldai reload');
}

sub print_status {
	wa_log("[STATUS] plugin_version=$VERSION mode=CONTROLLED_EXECUTION exec_state=$execution{state} auto_execute=" .
		(_auto_execute_enabled() ? 'on' : 'off') . ' movement_control=' .
		($runtime_override->active ? 'ON' : 'OFF') . ' target_control=' . ($runtime_override->active ? 'ON' : 'OFF') .
		' combat_policy=' . ($combat_runtime_override->active ? 'ON' : 'OFF'));
	wa_log(sprintf(
		'[STATUS] cpu_model=ON_DEMAND_SCORING background_hook=ACTIVE_STATE_MONITOR max_top_n=%d route_engine=Task::CalcMapRoute route_probe_timeout_ms=%d route_command_budget_ms=%d max_route_probes=%d exec_max_hops=%d',
		$MAX_TOP_N, $ROUTE_PROBE_WALL_TIMEOUT_MS, $ROUTE_COMMAND_BUDGET_MS, $MAX_ROUTE_PROBES_PER_COMMAND, $EXEC_MAX_HOPS,
	));
	wa_log('[STATUS] route_budget_zeny=0 special_routes=OFF');
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
		'[CHARACTER] base=%s job=%s class=%s map=%s hp=%s/%s sp=%s/%s atk=%s def=%s hit=%s flee=%s matk=%s mdef=%s',
		map { defined($_) ? $_ : 'undef' } @{$snapshot}{qw(base_level job_level job_name current_map hp hp_max sp sp_max attack_total defense_total hit flee attack_magic_avg def_magic_total)}
	));
	_log_skill_progress();
}

sub _current_map {
	return '' unless $field;
	return $field->baseName // '';
}

sub _in_game {
	return $net && $net->getState() == Network::IN_GAME && $char && $field;
}

sub _alive {
	return _in_game() && !($char->{dead} || 0) && ($char->{hp} || 0) > 0;
}

sub _transaction_in_progress {
	return AI::inQueue(qw(storageAuto buyAuto sellAuto teleport NPC skill_use eventMacro)) ? 1 : 0;
}

sub _auto_execute_enabled {
	my $value = $config{world_ai_auto_execute};
	return 0 unless defined $value;
	return $value =~ /^(?:1|yes|true|on)$/i ? 1 : 0;
}

sub _reset_execution {
	%execution = (
		state          => 'IDLE',
		started_at     => 0,
		state_since    => 0,
		deadline       => 0,
		start_map      => '',
		last_map       => '',
		target_map     => '',
		target_monster => '',
		target_id      => 0,
		static_rank    => 0,
		score          => undef,
		last_error     => '',
		attacks        => 0,
		kills          => 0,
		deaths         => 0,
		dead_seen      => 0,
		route_task     => undef,
		route_signature => '',
		depart_after   => 0,
		combat_policy  => undef,
	);
}

sub _execution_elapsed {
	return 0 unless $execution{started_at};
	return time - $execution{started_at};
}

sub _set_execution_state {
	my ($state) = @_;
	$execution{state} = $state;
	$execution{state_since} = time;
}

sub _same_task {
	my ($left, $right) = @_;
	return 0 unless blessed($left) && blessed($right);
	return refaddr($left) == refaddr($right);
}

sub _restore_runtime {
	my (%args) = @_;
	my $owned_route = $execution{route_task};
	my $cancel_owned = $args{cancel_owned} && $owned_route && (AI::action() || '') eq 'route'
		&& _same_task(AI::args(0), $owned_route);
	my $combat_restored = $combat_runtime_override->restore();
	my $movement_restored = $runtime_override->restore();
	Commands::run('move stop') if $cancel_owned && _in_game();
	$execution{route_task} = undef;
	return $combat_restored || $movement_restored;
}

sub _known_skills {
	my %known;
	return \%known unless $char && ref($char->{skills}) eq 'HASH';
	for my $handle (keys %{$char->{skills}}) {
		my $level = $char->{skills}{$handle}{lv} || 0;
		$known{$handle} = 0 + $level if $level > 0;
	}
	return \%known;
}

sub _log_skill_progress {
	return unless $char;
	my $job_id = $char->{jobID};
	my $family = $combat_policy->class_family(
		job_id => $job_id,
		job_name => $jobs_lut{$job_id} // "Class $job_id",
	);
	my %baseline = (
		THIEF_FAMILY    => ['TF_DOUBLE', 10, 'passive'],
		SWORDMAN_FAMILY => ['SM_BASH', 10, 'active'],
		MAGE_FAMILY     => ['MG_FIREBOLT', 10, 'active'],
		ARCHER_FAMILY   => ['AC_DOUBLE', 10, 'active'],
		ACOLYTE_FAMILY  => ['AL_HOLYLIGHT', 1, 'active'],
	);
	my $entry = $baseline{$family};
	unless ($entry) {
		wa_log("[SKILL_PROGRESS] class_family=$family baseline=none learned=0 target=0 ready=no");
		return;
	}
	my ($handle, $target, $role) = @$entry;
	my $known = _known_skills();
	my $level = $known->{$handle} || 0;
	wa_log(sprintf(
		'[SKILL_PROGRESS] class_family=%s baseline=%s role=%s learned=%d target=%d ready=%s',
		$family, $handle, $role, $level, $target, $level > 0 ? 'yes' : 'no',
	));
}

sub _attack_skill_slots {
	my @slots;
	for (my $i = 0; exists $config{"attackSkillSlot_$i"}; $i++) {
		my $configured = $config{"attackSkillSlot_$i"};
		next unless defined($configured) && _trim($configured) ne '';
		my $skill = eval { Skill->new(auto => $configured) };
		my $handle = $skill ? eval { $skill->getHandle() } : undef;
		my $name = $skill ? eval { $skill->getName() } : undef;
		push @slots, {
			index => $i,
			configured_skill => $configured,
			handle => $handle // '',
			name => $name // '',
			monsters => $config{"attackSkillSlot_${i}_monsters"},
			not_monsters => $config{"attackSkillSlot_${i}_notMonsters"},
		};
	}
	return \@slots;
}

sub _build_combat_policy {
	my (%args) = @_;
	my $job_id = $char ? $char->{jobID} : undef;
	return $combat_policy->evaluate(
		job_id => $job_id,
		job_name => defined($job_id) ? ($jobs_lut{$job_id} // "Class $job_id") : undef,
		known_skills => _known_skills(),
		attack_skill_slots => _attack_skill_slots(),
		target_monster_name => $args{target_monster_name},
		target_monster_id => $args{target_monster_id},
		target_map => $args{target_map},
	);
}

sub _combat_activation_signature {
	my ($policy) = @_;
	return '' unless $policy;
	return join('|',
		$policy->{class_family} // '',
		$policy->{mode} // '',
		map {
			join(':', $_->{skill_handle} // '', $_->{enabled} ? 1 : 0,
				join(',', @{$_->{slots} || []}))
		} @{$policy->{skills} || []},
	);
}

sub _uses_standard_arrows {
	return 0 unless $char;
	my $job = $jobs_lut{$char->{jobID}} // '';
	return $job =~ /(?:Archer|Hunter|Sniper|Ranger)/i ? 1 : 0;
}

sub _standard_arrow_count {
	return 0 unless $char && $char->inventory;
	return 0 + (eval { $char->inventory->sumByNameID(1750) } || 0);
}

sub _execution_resource_issue {
	return 'missing_ammo:item_id=1750' if _uses_standard_arrows() && _standard_arrow_count() < 1;
	return;
}

# 资源感知“回血闸门”：濒死（<40%）且无法自愈（没红药也没钱买最便宜红药）时，
# 不派新执行，让 sitAuto 先坐地回血，避免带着残血去送死。
sub _recovery_gate_reason {
	return 'not_ready' unless $char;
	my $hp = $char->{hp} || 0;
	my $hp_max = $char->{hp_max} || 0;
	my $zeny = $char->{zeny} || 0;
	my $potions = $char->inventory ? (eval { $char->inventory->sumByNameID(501) } || 0) : 0;
	my $hp_ratio = $hp_max > 0 ? $hp / $hp_max : 1;
	return 'low_hp_no_heal' if $hp_ratio < 0.4 && $potions < 1 && $zeny < 50;
	return;
}

# 濒死兜底：把“回血优先”下沉到原生战斗层。
# attackAuto=0 阻止原生 AI 主动打怪/跑图找怪；route_randomWalk=0 停止乱走；
# 再排队 sitAuto 让它真正坐下回血（而不是被 attackAuto 优先级盖过、带着残血去送死）。
sub _enter_recovery_mode {
	return if $recovery_mode{active};
	my %saved;
	for my $key (qw(attackAuto route_randomWalk)) {
		$saved{$key} = {
			existed => exists($config{$key}) ? 1 : 0,
			value   => $config{$key},
		};
	}
	$recovery_mode{saved} = \%saved;
	$recovery_mode{active} = 1;
	$config{attackAuto} = 0;
	$config{route_randomWalk} = 0;
	eval { AI::queue('sitAuto'); 1 };
	wa_warning('[RECOVER] enter recovery mode: attackAuto=0 route_randomWalk=0 (sit & regen first)');
}

sub _leave_recovery_mode {
	return unless $recovery_mode{active};
	my $saved = $recovery_mode{saved} || {};
	for my $key (qw(attackAuto route_randomWalk)) {
		my $s = $saved->{$key};
		if ($s && $s->{existed}) {
			$config{$key} = $s->{value};
		} else {
			delete $config{$key};
		}
	}
	$recovery_mode{saved} = {};
	$recovery_mode{active} = 0;
	wa_warning('[RECOVER] leave recovery mode: restored attackAuto/route_randomWalk');
}

sub _target_key {
	my ($monster_id, $map) = @_;
	return join('@', 0 + ($monster_id || 0), $map || '');
}

sub _register_monster_death {
	my ($monster_id) = @_;
	return unless $monster_id;
	$monster_stats{$monster_id}{deaths}++;
	my $s = $monster_stats{$monster_id};
	if ($s->{deaths} >= $MAX_GLOBAL_MONSTER_DEATHS && ($s->{kills} || 0) < $s->{deaths}) {
		$monster_cooldown{$monster_id} = time + $GLOBAL_MONSTER_COOLDOWN_S;
		wa_warning(sprintf(
			'[FEEDBACK_FILTER] global_monster_cooldown monster_id=%d deaths=%d kills=%d seconds=%d reason=repeated_deaths_across_maps',
			$monster_id, $s->{deaths}, $s->{kills} || 0, $GLOBAL_MONSTER_COOLDOWN_S,
		));
	}
}

sub _filter_feedback_cooldowns {
	my ($results) = @_;
	my $now = time;
	my @eligible;
	for my $candidate (@{$results || []}) {
		my $global_until = $monster_cooldown{$candidate->{monster_id}} || 0;
		if ($global_until > $now) {
			wa_log(sprintf('[FEEDBACK_FILTER] skipped %s (%d) global_monster_cooldown_remaining=%.0fs',
				$candidate->{monster_name}, $candidate->{monster_id}, $global_until - $now));
			next;
		}
		delete $monster_cooldown{$candidate->{monster_id}} if $global_until;

		my $key = _target_key($candidate->{monster_id}, $candidate->{target_map});
		my $until = $target_cooldown{$key} || 0;
		if ($until > $now) {
			wa_log(sprintf('[FEEDBACK_FILTER] skipped %s (%d) @ %s cooldown_remaining=%.0fs',
				$candidate->{monster_name}, $candidate->{monster_id}, $candidate->{target_map}, $until - $now));
			next;
		}
		delete $target_cooldown{$key} if $until;
		push @eligible, $candidate;
	}
	return \@eligible;
}

sub _fail_execution {
	my ($reason) = @_;
	my $previous = $execution{state};
	_restore_runtime(cancel_owned => 1);
	$execution{last_error} = $reason;
	_set_execution_state('ERROR');
	wa_warning("[EXEC] FAILED reason=$reason previous_state=$previous current_map=" .
		(_current_map() || 'unknown') . sprintf(' elapsed=%.1fs', _execution_elapsed()));
}

sub start_execution {
	if ($execution{state} ne 'IDLE' && $execution{state} ne 'ERROR') {
		wa_warning("[EXEC] rejected reason=already_active state=$execution{state}");
		return;
	}
	unless (_alive()) {
		wa_warning('[EXEC] rejected reason=character_not_ready_or_dead');
		return;
	}
	if (_transaction_in_progress()) {
		wa_warning('[EXEC] rejected reason=native_transaction_in_progress action=' . (AI::action() || 'none'));
		return;
	}
	if (AI::inQueue('sitAuto')) {
		wa_warning('[EXEC] rejected reason=character_recovering action=sitAuto');
		return;
	}
	if (my $resource_issue = _execution_resource_issue()) {
		wa_warning("[EXEC] rejected reason=$resource_issue");
		return;
	}
	my $ticket = eval { $char->inventory->getByNameID(7060) };
	if ($ticket && ($ticket->{amount} || 0) > 0) {
		wa_warning('[EXEC] rejected reason=route_ticket_present item_id=7060');
		return;
	}

	_restore_runtime(cancel_owned => 0) if $runtime_override->active || $combat_runtime_override->active;
	_reset_execution();
	_set_execution_state('SELECTING');
	$execution{started_at} = time;

	my ($snapshot, $results, $score_elapsed_ms) = _calculate_ranked();
	$results = _filter_feedback_cooldowns($results) if $results;
	unless ($results && @$results) {
		_fail_execution('no_allowed_candidate');
		return;
	}

	_set_execution_state('VALIDATING');
	my $validated = $route_probe->first_executable(
		candidates => $results,
		policy => $execution_policy,
		source_map => $snapshot->{current_map}, source_x => $snapshot->{pos_x}, source_y => $snapshot->{pos_y},
		max_probes => $MAX_ROUTE_PROBES_PER_COMMAND,
		per_probe_timeout_ms => $ROUTE_PROBE_WALL_TIMEOUT_MS,
		total_timeout_ms => $ROUTE_COMMAND_BUDGET_MS,
	);
	wa_log(sprintf(
		'[EXEC] selection static_score_ms=%.1f route_elapsed_ms=%s probes=%d policy=PORTAL_ONLY_FREE',
		$score_elapsed_ms, _route_value($validated->{elapsed_ms}), $validated->{probes_used},
	));
	for my $attempt (@{$validated->{attempts}}) {
		next if $attempt->{cached};
		my $candidate = $attempt->{candidate};
		my $route = $attempt->{result};
		my $policy = $attempt->{policy};
		wa_log(sprintf(
			'[EXEC_VALIDATE] static_rank=%d %s (%d) @ %s route=%s policy=%s reason=%s action=%s',
			$attempt->{static_rank}, $candidate->{monster_name}, $candidate->{monster_id},
			$candidate->{target_map}, $route->{status}, $policy->{allowed} ? 'ALLOWED' : 'REJECTED',
			$policy->{code}, $policy->{allowed} ? 'SELECTED' : 'SKIPPED',
		));
	}

	unless ($validated->{selected}) {
		my $reason = $validated->{limit_reached} ? 'route_probe_limit_reached'
			: $validated->{budget_reached} ? 'route_command_budget_reached'
			: 'no_policy_allowed_route';
		_fail_execution($reason);
		return;
	}

	my $selected = $validated->{selected};
	my $selected_attempt = $validated->{attempts}[-1];
	$execution{start_map} = $snapshot->{current_map};
	$execution{last_map} = $snapshot->{current_map};
	$execution{target_map} = $selected->{target_map};
	$execution{target_monster} = $selected->{monster_name};
	$execution{target_id} = $selected->{monster_id};
	$execution{static_rank} = $selected_attempt ? $selected_attempt->{static_rank} : 0;
	$execution{score} = $selected->{score};
	$execution{deadline} = time + $EXEC_SAFE_WAIT_SECONDS;
	_set_execution_state('WAITING_SAFE');
	wa_log(sprintf(
		'[EXEC] selected %s (%d) @ %s score=%.1f static_rank=%d state=WAITING_SAFE',
		@execution{qw(target_monster target_id target_map score static_rank)},
	), 'success');
	_advance_execution();
}

sub _apply_execution {
	my $ok = eval {
		$runtime_override->apply(
			target_map => $execution{target_map},
			monster => $execution{target_monster},
		);
		$execution{combat_policy} = _build_combat_policy(
			target_monster_name => $execution{target_monster},
			target_monster_id => $execution{target_id},
			target_map => $execution{target_map},
		);
		$combat_runtime_override->apply(policy => $execution{combat_policy});
		1;
	};
	unless ($ok) {
		my $error = $@ || 'runtime override failed';
		$error =~ s/\s+/ /g;
		_fail_execution("runtime_override_failed:$error");
		return;
	}

	$execution{deadline} = time + $EXEC_MOVE_TIMEOUT_SECONDS;
	_set_execution_state('MOVING');
	wa_log("[EXEC] runtime_override=APPLIED persistence=MEMORY_ONLY lockMap=$execution{target_map} " .
		"lock_coordinates=CLEARED paid_and_special_routes=DISABLED target=$execution{target_monster}");
	_log_combat_policy($execution{combat_policy}, prefix => 'COMBAT_POLICY');
	if (_current_map() eq $execution{target_map}) {
		_set_execution_state('ACTIVE');
		wa_log("[EXEC] ACTIVE map=$execution{target_map} monster=$execution{target_monster} arrival=same_map", 'success');
		return;
	}

	my $queued = eval {
		require Task::MapRoute;
		AI::clear(qw(move route mapRoute attack items_take items_gather take));
		my $task = Task::MapRoute->new(
			actor => $char,
			map => $execution{target_map},
			noGoCommand => 1,
			noTeleSpawn => 1,
			noAirship => 1,
			attackOnRoute => 0,
			isToLockMap => 1,
			notifyUponArrival => 1,
		);
		$char->queue('route', $task);
		$execution{route_task} = $task;
		$execution{route_signature} = '';
		1;
	};
	unless ($queued) {
		my $error = $@ || 'MapRoute queue failed';
		$error =~ s/\s+/ /g;
		_fail_execution("maproute_queue_failed:$error");
		return;
	}
	wa_log('[EXEC] navigation=QUEUED task=Task::MapRoute noGoCommand=1 noTeleSpawn=1 noAirship=1 maxWarpFee=0');
}

sub _advance_execution {
	return if $execution{state} eq 'IDLE' || $execution{state} eq 'ERROR';
	if ($execution{state} eq 'WAITING_SAFE') {
		if (time >= $execution{deadline}) {
			_fail_execution('safe_state_timeout');
			return;
		}
		return unless _alive();
		return if _transaction_in_progress();
		return if $execution{depart_after} && time < $execution{depart_after};
		my $safe_to_depart = AI::isIdle() || $execution{depart_after}
			|| AI::is(qw(route move));
		return unless $safe_to_depart;
		_apply_execution();
		return;
	}

	if ($execution{state} eq 'MOVING') {
		my $map = _current_map();
		if ($map && $map ne $execution{last_map}) {
			wa_log("[EXEC] map_changed $execution{last_map} -> $map");
			$execution{last_map} = $map;
		}
		if ($map eq $execution{target_map}) {
			$execution{route_task} = undef;
			_set_execution_state('ACTIVE');
			wa_log(sprintf('[EXEC] ACTIVE map=%s monster=%s arrival_elapsed=%.1fs',
				$execution{target_map}, $execution{target_monster}, _execution_elapsed()), 'success');
			return;
		}
		if ($execution{route_task}) {
			my $solution = $execution{route_task}{mapSolution};
			if (ref($solution) eq 'ARRAY' && @$solution) {
				my $signature = join('|', map {
					join(':', map { defined($_) ? $_ : '' }
						@{$_}{qw(portal walk zeny amount_of_tickets_used is_command is_airship is_teleportToSaveMap is_teleportItemWarp)})
				} @$solution);
				if ($signature ne ($execution{route_signature} || '')) {
					my $metadata = WorldAI::RouteProbe->parse_route_metadata($solution);
					my $checked = $execution_policy->evaluate({ status => 'REACHABLE', %$metadata });
					if (!$checked->{allowed}) {
						_fail_execution("runtime_route_policy_rejected:$checked->{code}");
						return;
					}
					$execution{route_signature} = $signature;
					wa_log(sprintf(
						'[EXEC] runtime_route_policy=ALLOWED hops=%s zeny=%s tickets=%s npc=%s command=%s airship=%s save_teleport=%s warp_item=%s',
						map { defined($metadata->{$_}) ? $metadata->{$_} : 'undef' }
							qw(route_hops route_zeny route_tickets uses_npc uses_command uses_airship uses_save_teleport uses_warp_item),
					));
				}
			}
			my $task_status = eval { $execution{route_task}->getStatus() };
			if (defined($task_status) && $task_status == Task::DONE) {
				my $error = eval { $execution{route_task}->getError() };
				my $detail = $error ? (($error->{code} // 'unknown') . ':' . ($error->{message} // 'unknown'))
					: 'ended_before_target';
				$detail =~ s/\s+/ /g;
				_fail_execution("maproute_done_before_target:$detail");
				return;
			} elsif (defined($task_status) && $task_status == Task::STOPPED) {
				_fail_execution('maproute_stopped_before_target');
				return;
			}
		}
		if (time >= $execution{deadline}) {
			_fail_execution('movement_timeout');
			return;
		}
	}

	if ($execution{state} eq 'ACTIVE') {
		if (my $resource_issue = _execution_resource_issue()) {
			_fail_execution($resource_issue);
			return;
		}
		if ($execution{kills} == 0 && $execution{attacks} >= $MAX_NO_KILL_ATTACKS &&
			_execution_elapsed() >= $MAX_NO_KILL_ELAPSED_S) {
			my $key = _target_key($execution{target_id}, $execution{target_map});
			$target_cooldown{$key} = time + $TARGET_FAILURE_COOLDOWN_S;
			wa_warning("[FEEDBACK_FILTER] cooldown_applied target=$execution{target_monster} map=$execution{target_map} seconds=$TARGET_FAILURE_COOLDOWN_S reason=no_kill_progress");
			_fail_execution('no_kill_progress');
			return;
		}
		my $map = _current_map();
		if ($map && $map ne $execution{last_map}) {
			wa_log("[EXEC] native_detour $execution{last_map} -> $map action=" . (AI::action() || 'none'));
			$execution{last_map} = $map;
		}
	}
}

sub maybe_auto_execute {
	return unless _auto_execute_enabled();
	return unless _in_game() && _alive();
	my $state = $execution{state};
	return unless $state eq 'IDLE' || $state eq 'ERROR';
	return if _transaction_in_progress();

	# 资源感知：濒死且无续航时先坐地回血，不要派新执行。
	if (my $recovery = _recovery_gate_reason()) {
		my $now = time;
		if ($now - $recovery_gate_last_warn >= 30) {
			$recovery_gate_last_warn = $now;
			wa_log("[AUTO_EXEC] deferred reason=$recovery (sit & recover first)");
		}
		return;
	}

	my $now = time;
	return if $now - $auto_execute_last_attempt < $auto_execute_backoff_s;
	$auto_execute_last_attempt = $now;

	wa_log(sprintf('[AUTO_EXEC] attempt state=%s backoff=%ds', $state, $auto_execute_backoff_s));
	start_execution();
	if ($execution{state} eq 'IDLE' || $execution{state} eq 'ERROR') {
		$auto_execute_backoff_s = $auto_execute_backoff_s == 0
			? 15
			: ($auto_execute_backoff_s * 2 > $AUTO_EXECUTE_MAX_BACKOFF_S
				? $AUTO_EXECUTE_MAX_BACKOFF_S : $auto_execute_backoff_s * 2);
		wa_log(sprintf('[AUTO_EXEC] failed state=%s next_backoff=%ds', $execution{state}, $auto_execute_backoff_s));
	} else {
		$auto_execute_backoff_s = 0;
		wa_log(sprintf('[AUTO_EXEC] started state=%s', $execution{state}), 'success');
	}
}

sub on_ai_pre {
	if ($execution{state} eq 'ACTIVE' && !_alive()) {
		unless ($execution{dead_seen}) {
			$execution{dead_seen} = 1;
			$execution{deaths}++;
			wa_warning("[EXEC] character_death target=$execution{target_monster} deaths=$execution{deaths} kills=$execution{kills}");
			_register_monster_death($execution{target_id});
			if (($execution{kills} == 0 && $execution{deaths} >= $MAX_ZERO_KILL_DEATHS) ||
				($execution{deaths} >= $MAX_LOW_PROGRESS_DEATHS && $execution{kills} < $execution{deaths})) {
				my $key = _target_key($execution{target_id}, $execution{target_map});
				$target_cooldown{$key} = time + $TARGET_FAILURE_COOLDOWN_S;
				wa_warning("[FEEDBACK_FILTER] cooldown_applied target=$execution{target_monster} map=$execution{target_map} seconds=$TARGET_FAILURE_COOLDOWN_S reason=repeated_deaths_low_progress");
				_fail_execution('repeated_deaths_low_progress');
			}
		}
		return;
	}
	$execution{dead_seen} = 0 if $execution{state} eq 'ACTIVE';

	# 资源感知兜底：濒死且无法自愈时，暂停原生战斗并坐地回血；恢复后自动还原。
	if (_alive() && _recovery_gate_reason()) {
		_enter_recovery_mode();
		return;
	}
	_leave_recovery_mode();

	maybe_auto_execute();
	return if $execution{state} eq 'IDLE' || $execution{state} eq 'ERROR';
	my $ok = eval { _advance_execution(); 1 };
	unless ($ok) {
		my $error = $@ || 'unknown monitor failure';
		$error =~ s/\s+/ /g;
		_fail_execution("monitor_exception:$error");
	}
}

sub on_skill_update {
	return unless ($execution{state} eq 'ACTIVE' || $execution{state} eq 'MOVING') &&
		$combat_runtime_override->active;
	my $updated = _build_combat_policy(
		target_monster_name => $execution{target_monster},
		target_monster_id => $execution{target_id},
		target_map => $execution{target_map},
	);
	return if _combat_activation_signature($updated) eq
		_combat_activation_signature($execution{combat_policy});

	$combat_runtime_override->restore();
	$execution{combat_policy} = $updated;
	$combat_runtime_override->apply(policy => $updated);
	wa_log('[COMBAT_REFRESH] reason=learned_skill_state_changed', 'success');
	_log_combat_policy($updated, prefix => 'COMBAT_REFRESH');
}

sub on_attack_start {
	my (undef, $args) = @_;
	return unless $execution{state} eq 'ACTIVE' && $args->{ID};
	my $monster = eval { $Globals::monstersList->getByID($args->{ID}) };
	return unless $monster && lc($monster->name // '') eq lc($execution{target_monster});
	$execution{attacks}++;
	wa_log("[EXEC] target_attack_started monster=$execution{target_monster} count=$execution{attacks}", 'success');
}

sub on_target_died {
	my (undef, $args) = @_;
	if ($execution{state} eq 'WAITING_SAFE') {
		$execution{depart_after} = time + 1.5;
		wa_log('[EXEC] current_combat_finished departure_scheduled=yes');
		return;
	}
	return unless $execution{state} eq 'ACTIVE';
	my $monster = $args->{monster};
	return unless $monster && lc($monster->name // '') eq lc($execution{target_monster});
	return unless ($monster->{dmgFromYou} || 0) > 0;
	$execution{kills}++;
	$monster_stats{$execution{target_id}}{kills}++;
	wa_log("[EXEC] target_kill_confirmed monster=$execution{target_monster} kills=$execution{kills}", 'success');
}

sub on_buy_auto_needitem {
	my (undef, $args) = @_;
	return unless $char && $net && $net->getState() == Network::IN_GAME;

	# Guard against the "broke bot" buyAuto loop: OpenKore triggers buyAuto purely
	# on item count (minAmount) and only checks zeny while buying, so a penniless
	# character queues buy -> buys nothing -> "completes" -> triggers again every few
	# seconds. Skip the trigger entirely when zeny cannot afford the cheapest item.
	my $zeny = 0 + ($char->{zeny} || 0);
	my $min_price;
	for (my $i = 0; exists $config{"buyAuto_$i"}; $i++) {
		next unless $config{"buyAuto_$i"} && $config{"buyAuto_${i}_npc"} && !$config{"buyAuto_${i}_disabled"};
		my $price = $config{"buyAuto_${i}_price"};
		next unless $price && $price =~ /^\d+$/ && $price > 0;
		$min_price = $price if !defined($min_price) || $price < $min_price;
	}
	return unless defined($min_price);
	return if $zeny >= $min_price;

	$args->{return} = 1;
	my $now = time;
	return if $now - $buy_guard_last_warn < 60;
	$buy_guard_last_warn = $now;
	wa_warning(sprintf(
		'[BUY_GUARD] skipped buyAuto zeny=%d cheapest_price=%d',
		$zeny, $min_price,
	));
}

sub print_execution_status {
	wa_log(sprintf(
		'[EXEC_STATUS] state=%s active_override=%s current_map=%s start_map=%s target_map=%s target_monster=%s target_id=%s static_rank=%s score=%s elapsed=%.1fs ai_action=%s attacks=%d kills=%d deaths=%d last_error=%s',
		$execution{state}, $runtime_override->active ? 'yes' : 'no', _current_map() || 'unknown',
		map { defined($_) && $_ ne '' ? $_ : 'none' }
			@execution{qw(start_map target_map target_monster target_id static_rank score)},
		_execution_elapsed(), AI::action() || 'none', $execution{attacks}, $execution{kills}, $execution{deaths},
		$execution{last_error} || 'none',
	));
	_log_combat_policy($execution{combat_policy}, prefix => 'EXEC_COMBAT') if $execution{combat_policy};
}

sub stop_execution {
	my ($reason) = @_;
	if ($execution{state} eq 'IDLE' && !$runtime_override->active && !$combat_runtime_override->active) {
		wa_log('[EXEC_STOP] no_active_execution');
		return;
	}
	my $previous = $execution{state};
	my $restored = _restore_runtime(cancel_owned => 1);
	wa_log("[EXEC_STOP] reason=$reason previous_state=$previous restored=" . ($restored ? 'yes' : 'not_needed') .
		' native_transactions_preserved=yes', 'success');
	_reset_execution();
}

sub _display_filter {
	my ($value) = @_;
	return '<all>' unless defined($value) && _trim($value) ne '';
	return $value;
}

sub _log_combat_policy {
	my ($policy, %args) = @_;
	return unless $policy;
	my $prefix = $args{prefix} || 'COMBAT_POLICY';
	wa_log(sprintf(
		'[%s] class_family=%s mode=%s target=%s target_id=%s target_map=%s normal_attack_fallback=%s runtime_override=%s',
		$prefix,
		$policy->{class_family} // 'UNSUPPORTED', $policy->{mode} // 'NORMAL_ATTACK_BASELINE',
		$policy->{target_monster_name} || 'none', $policy->{target_monster_id} || 'none',
		$policy->{target_map} || 'none', $policy->{fallback_normal_attack} ? 'ON' : 'OFF',
		$combat_runtime_override->active ? 'ON' : 'OFF',
	));
	if (!@{$policy->{skills} || []}) {
		wa_log("[$prefix] active_skills=none");
		return;
	}
	for my $skill (@{$policy->{skills}}) {
		wa_log(sprintf(
			'[%s_SKILL] handle=%s learned_level=%d enabled=%s slots=%s reason=%s',
			$prefix, $skill->{skill_handle}, $skill->{known_level} || 0,
			$skill->{enabled} ? 'yes' : 'no',
			@{$skill->{slots} || []} ? join(',', @{$skill->{slots}}) : 'none',
			$skill->{reason} || 'none',
		));
	}
	for my $override (@{$combat_runtime_override->overrides}) {
		wa_log(sprintf(
			'[%s_SYNC] slot=%d handle=%s changed=%s monsters=%s',
			$prefix, $override->{slot}, $override->{skill_handle} || 'unknown',
			$override->{changed} ? 'yes' : 'already_allowed', _display_filter($override->{applied_filter}),
		));
	}
}

sub print_combat_inspect {
	my $target_name = $execution{target_monster} || '';
	my $policy = _build_combat_policy(
		target_monster_name => $target_name,
		target_monster_id => $execution{target_id} || undef,
		target_map => $execution{target_map} || undef,
	);
	my $job_id = $char ? $char->{jobID} : undef;
	wa_log(sprintf(
		'[COMBAT_INSPECT] character_class=%s job_id=%s executed_target=%s execution_state=%s',
		defined($job_id) ? ($jobs_lut{$job_id} // "Class $job_id") : 'unavailable',
		defined($job_id) ? $job_id : 'none', $target_name || 'none', $execution{state},
	));
	my $known = _known_skills();
	wa_log('[COMBAT_INSPECT] known_skills=' .
		(keys(%$known) ? join(', ', map { "$_(Lv$known->{$_})" } sort keys %$known) : 'none'));
	my $slots = _attack_skill_slots();
	if (@$slots) {
		for my $slot (@$slots) {
			wa_log(sprintf(
				'[COMBAT_SLOT] slot=%d configured=%s handle=%s learned_level=%d monsters=%s notMonsters=%s',
				$slot->{index}, $slot->{configured_skill}, $slot->{handle} || 'unresolved',
				$known->{$slot->{handle}} || 0, _display_filter($slot->{monsters}),
				_display_filter($slot->{not_monsters}),
			));
		}
	} else {
		wa_log('[COMBAT_SLOT] none');
	}
	_log_combat_policy($policy, prefix => 'COMBAT_INSPECT_POLICY');
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

	$scorer->set_combat_context(
		known_skills       => _known_skills(),
		attack_skill_slots => _attack_skill_slots(),
		element_table      => $index->element_table,
		archer_has_ammo    => (_execution_resource_issue() ? 0 : 1),
	);

	my $started = time;
	my $results = _all_candidates($snapshot);
	my $elapsed_ms = (time - $started) * 1000;
	return ($snapshot, $results, $elapsed_ms);
}

sub _print_breakdown {
	my ($result) = @_;
	my $b = $result->{breakdown};
	wa_log(sprintf(
		'  breakdown: +level_fit=%s +exp_value=%s +spawn_count_score=%s +class_match=%s -kill_cost=%s -defense_penalty=%s -target_risk=%s -map_risk=%s',
		map { _fmt($b->{$_}) } qw(level_fit exp_value spawn_count_score class_match kill_cost defense_penalty target_risk map_risk)
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
	wa_log(sprintf(
		'  combat: class=%s estimate=%s damage=%s power=%s kill_cost=%s element_factor=%s vuln=%s degraded=%s',
		map { defined($_) ? $_ : 'n/a' }
			@{$result}{qw(class_family estimate_mode damage_type effective_power estimated_kill_cost element_factor vulnerability)},
		$result->{degraded} ? 'yes' : 'no',
	));
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
	wa_log('  estimated_kill_cost=' . _fmt($results->[0]{estimated_kill_cost}) .
		' estimate_mode=' . ($results->[0]{estimate_mode} // 'n/a'));
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
	my $previous = $execution{state};
	my $restored = _restore_runtime(cancel_owned => 1);
	Plugins::delHooks($hooks) if $hooks;
	Commands::unregister($commands) if $commands;
	wa_log("[PLUGIN] unloaded previous_exec_state=$previous runtime_restored=" . ($restored ? 'yes' : 'not_needed'));
}

1;
