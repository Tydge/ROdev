package WorldAI::Scorer;

use strict;
use warnings;

use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);

use WorldAI::ClassProfile;
use WorldAI::CombatEstimate;

my %DEFAULTS = (
	MAX_LEVEL_ABOVE       => 8,
	MAX_LEVEL_BELOW       => 15,
	# Targets needing dozens of normal attacks looked attractive on EXP alone but
	# were not sustainable in live play (a level-27 Swordman repeatedly died to
	# Savage at ~26 estimated hits and never completed a kill).
	MAX_KILL_COST_PHYSICAL => 20,
	MAX_KILL_COST_MAGIC    => 24,
	MAX_ATTACK_HP_RATIO   => 0.65,
	LEVEL_FIT_WEIGHT      => 1.0,
	EXP_WEIGHT            => 1.0,
	SPAWN_COUNT_WEIGHT    => 1.0,
	KILL_COST_WEIGHT      => 1.0,
	TARGET_RISK_WEIGHT    => 1.0,
	MAP_RISK_WEIGHT       => 1.0,
	CLASS_MATCH_WEIGHT    => 1.0,
	DEFENSE_PENALTY_WEIGHT => 1.0,
	CLASS_MATCH_BONUS     => 3.0,
	RANGED_RISK_WEIGHT    => 1.2,
	RANGED_RISK_RANGED_FACTOR => 0.7,

	# Novice (job_id == 0) has no first-job skills, no weapon mastery and far
	# weaker combat output than a first-job character of the same base level.
	NOVICE_MAX_LEVEL_ABOVE        => 0,    # never fight monsters above own level
	NOVICE_MAX_MONSTER_ATTACK     => 20,   # hard cap on monster max attack
	NOVICE_MAX_ATTACK_HP_RATIO    => 0.25, # single monster hit < 25% of max HP
	NOVICE_MAX_ESTIMATED_HITS     => 15,   # kill must be affordable in few hits
	NOVICE_TARGET_RISK_MULTIPLIER => 1.6,  # extra risk weight for Novices
);

sub new {
	my ($class, %args) = @_;
	my %config = (%DEFAULTS, %{$args{config} || {}});
	return bless {
		config          => \%config,
		combat_estimate => WorldAI::CombatEstimate->new(config => $args{combat_estimate_config}),
		context         => {
			known_skills       => {},
			attack_skill_slots => [],
			element_table      => undef,
			archer_has_ammo    => 1,
		},
	}, $class;
}

sub config { return { %{$_[0]->{config}} }; }

sub set_combat_context {
	my ($self, %args) = @_;
	$self->{context}{known_skills} = $args{known_skills} || {};
	$self->{context}{attack_skill_slots} = $args{attack_skill_slots} || [];
	$self->{context}{element_table} = $args{element_table};
	$self->{context}{archer_has_ammo} = defined($args{archer_has_ammo}) ? $args{archer_has_ammo} : 1;
	return 1;
}

sub _num {
	my ($value, $default) = @_;
	return $default unless defined $value && looks_like_number($value);
	return 0 + $value;
}

sub _is_novice {
	my ($snapshot) = @_;
	return _num($snapshot->{job_id}, -1) == 0;
}

sub _boss_on_map {
	my ($monster, $map) = @_;
	return 0 unless ref($monster->{boss_spawn_maps}) eq 'ARRAY';
	return scalar grep { defined($_) && $_ eq $map } @{$monster->{boss_spawn_maps}};
}

sub _combat_estimate {
	my ($self, $snapshot, $monster) = @_;
	my $family = WorldAI::ClassProfile::class_family(
		job_id => $snapshot->{job_id}, job_name => $snapshot->{job_name});
	my $profile = WorldAI::ClassProfile::profile($family);
	my $skill_state = WorldAI::ClassProfile::baseline_skill_state(
		family              => $family,
		known_skills        => $self->{context}{known_skills},
		attack_skill_slots  => $self->{context}{attack_skill_slots},
		target_monster_name => $monster->{name},
		target_monster_id   => $monster->{id},
	);
	return $self->{combat_estimate}->estimate(
		snapshot        => $snapshot,
		monster         => $monster,
		profile         => $profile,
		skill_state     => $skill_state,
		known_skills    => $self->{context}{known_skills},
		element_table   => $self->{context}{element_table},
		archer_has_ammo => $self->{context}{archer_has_ammo},
	);
}

sub hard_filter {
	my ($self, $snapshot, $monster, $map) = @_;
	my @reasons;
	return (0, ['invalid monster data']) unless ref $monster eq 'HASH';

	my $char_level = _num($snapshot->{base_level}, 0);
	my $monster_level = _num($monster->{level}, 0);
	my $hp_max = _num($snapshot->{hp_max}, 0);
	my $attack_max = max(_num($monster->{attack}, 0), _num($monster->{attack2}, 0));
	my $diff = $monster_level - $char_level;
	my $is_novice = _is_novice($snapshot);

	my $max_level_above  = $is_novice ? $self->{config}{NOVICE_MAX_LEVEL_ABOVE}    : $self->{config}{MAX_LEVEL_ABOVE};
	my $max_attack_ratio = $is_novice ? $self->{config}{NOVICE_MAX_ATTACK_HP_RATIO} : $self->{config}{MAX_ATTACK_HP_RATIO};

	push @reasons, 'MVP excluded' if $monster->{is_mvp};
	push @reasons, 'boss spawn excluded' if _boss_on_map($monster, $map);
	push @reasons, "monster level is more than $max_level_above above character"
		if $diff > $max_level_above;
	push @reasons, "monster level is more than $self->{config}{MAX_LEVEL_BELOW} below character"
		if $diff < -$self->{config}{MAX_LEVEL_BELOW};

	push @reasons, 'novice: monster attack exceeds novice limit'
		if $is_novice && $attack_max > $self->{config}{NOVICE_MAX_MONSTER_ATTACK};

	my $estimate = $self->_combat_estimate($snapshot, $monster);
	# 硬过滤用“裸攻击力”（ATK/MATK，不含技能/被动/元素倍率）估算击杀成本。
	# 技能依赖 SP 与咏唱、被动与元素是评分层面的期望加成，不该拿来穿透安全阈值：
	# 否则 Thief 的 Double Attack 被动会把 Wolf 从 20.9 次拉低到 13.9 次而放行致死。
	my $raw_power = _num($estimate->{raw_power}, 0);
	my $kill_cost = $raw_power > 0
		? _num($monster->{hp}, 0) / $raw_power
		: $estimate->{estimated_kill_cost};
	my $max_kill_cost = $is_novice ? $self->{config}{NOVICE_MAX_ESTIMATED_HITS}
		: ($estimate->{damage_type} eq 'MAGIC'
			? $self->{config}{MAX_KILL_COST_MAGIC}
			: $self->{config}{MAX_KILL_COST_PHYSICAL});
	push @reasons, $is_novice ? 'novice: estimated kill cost is too high' : 'estimated kill cost is extreme'
		if $kill_cost > $max_kill_cost;
	push @reasons, $is_novice ? 'novice: single-hit damage risk is too high' : 'single-hit damage risk is extreme'
		if $hp_max > 0 && $attack_max / $hp_max >= $max_attack_ratio;
	push @reasons, 'invalid monster HP' if _num($monster->{hp}, 0) <= 0;

	return @reasons ? (0, \@reasons) : (1, []);
}

sub _level_fit {
	my ($diff) = @_;
	return max(0, 20 + $diff) if $diff < -5;
	return max(0, 25 - abs($diff) * ($diff > 0 ? 1.3 : 0.8)) if $diff <= 2;
	return max(0, 20 - ($diff - 3) * 3) if $diff <= 5;
	return max(0, 10 - ($diff - 6) * 2.5);
}

sub _range_risk {
	my ($self, $monster, $estimate) = @_;
	my $range = _num($monster->{attack_range}, 1);
	my $factor = $self->{config}{RANGED_RISK_WEIGHT};
	my $style = $estimate->{combat_style} || 'MELEE';
	$factor *= $self->{config}{RANGED_RISK_RANGED_FACTOR}
		if $style eq 'RANGED' || $style eq 'RANGED_CAST';
	return min(8, max(0, $range - 1) * $factor);
}

sub _survival_factor {
	my ($self, $snapshot) = @_;
	# 使用真实面板 DEF 做小幅风险修正，不按职业族硬编码生存加成。
	my $defense_total = _num($snapshot->{defense_total}, 0);
	return 1.0 unless $defense_total > 0;
	return max(0.85, 1 - min(0.15, $defense_total / 200));
}

sub _target_risk {
	my ($self, $snapshot, $monster, $estimate) = @_;
	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $hp_max = max(1, _num($snapshot->{hp_max}, 1));
	my $attack_max = max(_num($monster->{attack}, 0), _num($monster->{attack2}, 0));
	my $attack_ratio = $attack_max / $hp_max;
	my $kill_cost = $estimate->{estimated_kill_cost};

	my $risk = max(0, $diff - 2) * 1.5;
	$risk += max(0, $attack_ratio - 0.08) * 20;
	$risk += $kill_cost > 12 ? log($kill_cost / 12) * 5 : 0;
	$risk += $self->_range_risk($monster, $estimate);
	$risk += 4 if $diff > 4 && $attack_ratio > 0.20;
	$risk *= $self->_survival_factor($snapshot);
	$risk *= $self->{config}{NOVICE_TARGET_RISK_MULTIPLIER} if _is_novice($snapshot);
	return min(30, max(0, $risk));
}

sub _map_danger {
	my ($self, $snapshot, $monster, $map, $spawn_count) = @_;
	my $estimate = $self->_combat_estimate($snapshot, $monster);
	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $hp_max = max(1, _num($snapshot->{hp_max}, 1));
	my $attack_max = max(_num($monster->{attack}, 0), _num($monster->{attack2}, 0));
	my $attack_ratio = $attack_max / $hp_max;
	my $kill_cost = $estimate->{estimated_kill_cost};
	my $range = _num($monster->{attack_range}, 1);

	my $danger = 0;
	$danger += max(0, $diff - 2) * 1.2;
	$danger += max(0, $attack_ratio - 0.12) * 18;
	$danger += $kill_cost > 20 ? log($kill_cost / 20) * 5 : 0;
	$danger += min(6, max(0, $range - 1));

	# 怪物 Mode 修正（co-spawn 威胁）。Boss 危险保持全额，不受被动减免。
	my $mode = $monster->{mode} || {};
	my $aggressive = $mode->{aggressive} ? 1 : 0;
	my $cast_sensor = $mode->{cast_sensor} ? 1 : 0;
	my $assist = $mode->{assist} ? 1 : 0;
	my $is_boss = $monster->{is_mvp} || _boss_on_map($monster, $map);
	if (!$is_boss && !$aggressive && !$cast_sensor && !$assist) {
		$danger *= 0.4;   # 完全被动的 co-spawn 明显更安全
	}
	if ($cast_sensor && (($estimate->{combat_style} || '') eq 'RANGED_CAST')) {
		$danger *= 1.3;   # 施法职业更怕 Cast Sensor
	}
	$danger += 35 if $is_boss;

	my $count = max(0, _num($spawn_count, 0));
	my $spawn_weight = 0.30 + 0.70 * min(1, log(1 + $count) / log(101));
	$danger *= $self->{config}{NOVICE_TARGET_RISK_MULTIPLIER} if _is_novice($snapshot);
	return ($danger, $danger * $spawn_weight);
}

sub prepare_map_profile {
	my ($self, $snapshot, $map, $map_spawns, $monster_lookup) = @_;
	my %contributions;
	my $total = 0;
	for my $id (sort { $a <=> $b } keys %{$map_spawns || {}}) {
		my $monster = $monster_lookup->($id);
		next unless $monster;
		my ($danger, $weighted) = $self->_map_danger(
			$snapshot, $monster, $map, $map_spawns->{$id}
		);
		$contributions{$id} = {
			danger       => $danger,
			weighted     => $weighted,
			spawn_count  => 0 + $map_spawns->{$id},
		};
		$total += $weighted;
	}
	return { total => $total, contributions => \%contributions };
}

sub _class_match {
	my ($self, $estimate) = @_;
	my $mode = $estimate->{estimate_mode};
	return $self->{config}{CLASS_MATCH_BONUS} * $self->{config}{CLASS_MATCH_WEIGHT}
		if $mode eq 'PHYSICAL_SKILL' || $mode eq 'MAGIC_SKILL';
	return 0;
}

sub score_candidate {
	my ($self, $snapshot, $monster, $map, $spawn_count, $map_profile) = @_;
	my ($allowed, $filter_reasons) = $self->hard_filter($snapshot, $monster, $map);
	return {
		allowed => 0,
		score => undef,
		risk => 'BLOCKED',
		breakdown => {},
		reasons => $filter_reasons,
	} unless $allowed;

	my $estimate = $self->_combat_estimate($snapshot, $monster);
	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $level_fit = _level_fit($diff) * $self->{config}{LEVEL_FIT_WEIGHT};
	my $total_exp = max(0, _num($monster->{base_exp}, 0) + _num($monster->{job_exp}, 0));
	my $exp_value = min(24, log(1 + $total_exp) * 3.5) * $self->{config}{EXP_WEIGHT};
	my $spawn_score = min(18, log(1 + max(0, _num($spawn_count, 0))) * 4)
		* $self->{config}{SPAWN_COUNT_WEIGHT};
	my $kill_cost = min(22, log(1 + max(0, $estimate->{estimated_kill_cost})) * 5)
		* $self->{config}{KILL_COST_WEIGHT};
	my $defense_penalty = $estimate->{defense_penalty} * $self->{config}{DEFENSE_PENALTY_WEIGHT};
	my $class_match = $self->_class_match($estimate);
	my $target_risk = $self->_target_risk($snapshot, $monster, $estimate) * $self->{config}{TARGET_RISK_WEIGHT};

	my $own_map_risk = $map_profile->{contributions}{$monster->{id}}{weighted} // 0;
	my $map_risk = min(35, max(0, ($map_profile->{total} // 0) - $own_map_risk))
		* $self->{config}{MAP_RISK_WEIGHT};
	my $score = $level_fit + $exp_value + $spawn_score + $class_match
		- $kill_cost - $defense_penalty - $target_risk - $map_risk;

	my @reasons;
	push @reasons, 'monster level close to character' if abs($diff) <= 2;
	push @reasons, 'high spawn count' if $spawn_count >= 40;
	push @reasons, 'good static EXP value' if $exp_value >= 14;
	push @reasons, 'ranged basic attack' if _num($monster->{attack_range}, 1) > 1;
	push @reasons, 'dangerous co-spawns on map' if $map_risk >= 5;
	push @reasons, @{$estimate->{reasons}} if @{$estimate->{reasons}};

	my $combined_risk = $target_risk + $map_risk;
	my $risk = $combined_risk < 10 ? 'LOW' : $combined_risk < 22 ? 'MEDIUM' : 'HIGH';
	return {
		allowed => 1,
		score => $score,
		risk => $risk,
		breakdown => {
			level_fit        => $level_fit,
			exp_value        => $exp_value,
			spawn_count_score => $spawn_score,
			class_match      => $class_match,
			kill_cost        => $kill_cost,
			defense_penalty  => $defense_penalty,
			target_risk      => $target_risk,
			map_risk         => $map_risk,
		},
		reasons => \@reasons,
		estimated_hits      => $estimate->{estimated_kill_cost},
		estimated_kill_cost => $estimate->{estimated_kill_cost},
		estimate_mode       => $estimate->{estimate_mode},
		class_family        => WorldAI::ClassProfile::class_family(
			job_id => $snapshot->{job_id}, job_name => $snapshot->{job_name}),
		damage_type         => $estimate->{damage_type},
		effective_power     => $estimate->{effective_power},
		raw_power           => $estimate->{raw_power},
		defense_penalty_val => $defense_penalty,
		element_factor      => $estimate->{element_factor},
		degraded            => $estimate->{degraded},
		travel_cost => undef,
		route_reachability => 'UNVERIFIED',
	};
}

1;
