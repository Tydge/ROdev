package WorldAI::Scorer;

use strict;
use warnings;

use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);

my %DEFAULTS = (
	MAX_LEVEL_ABOVE       => 8,
	MAX_LEVEL_BELOW       => 15,
	# Targets needing dozens of normal attacks looked attractive on EXP alone but
	# were not sustainable in live play (a level-27 Swordman repeatedly died to
	# Savage at ~26 estimated hits and never completed a kill).
	MAX_ESTIMATED_HITS    => 20,
	MAX_ATTACK_HP_RATIO   => 0.65,
	LEVEL_FIT_WEIGHT      => 1.0,
	EXP_WEIGHT            => 1.0,
	SPAWN_COUNT_WEIGHT    => 1.0,
	KILL_COST_WEIGHT      => 1.0,
	TARGET_RISK_WEIGHT    => 1.0,
	MAP_RISK_WEIGHT       => 1.0,
	RANGED_RISK_WEIGHT    => 1.2,

	# Novice (job_id == 0) has no first-job skills, no weapon mastery and far
	# weaker combat output than a first-job character of the same base level.
	# A level-only fit therefore sends Novices against monsters they cannot
	# kill before dying (observed: Baby Desert Wolf killing a level-12 Novice
	# every ~75s). Apply tighter hard filters and extra risk for Novices.
	NOVICE_MAX_LEVEL_ABOVE        => 0,    # never fight monsters above own level
	NOVICE_MAX_MONSTER_ATTACK     => 20,   # hard cap on monster max attack
	NOVICE_MAX_ATTACK_HP_RATIO    => 0.25, # single monster hit < 25% of max HP
	NOVICE_MAX_ESTIMATED_HITS     => 15,   # kill must be affordable in few hits
	NOVICE_TARGET_RISK_MULTIPLIER => 1.6,  # extra risk weight for Novices
);

sub new {
	my ($class, %args) = @_;
	my %config = (%DEFAULTS, %{$args{config} || {}});
	return bless { config => \%config }, $class;
}

sub config { return { %{$_[0]->{config}} }; }

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

sub _estimated_hits {
	my ($snapshot, $monster) = @_;
	my $attack = _num($snapshot->{attack_total}, 0);
	if ($attack > 0) {
		return (_num($monster->{hp}, 0) / max(1, $attack), 0);
	}
	my $fallback_attack = max(20, _num($snapshot->{base_level}, 1) * 5);
	return (_num($monster->{hp}, 0) / $fallback_attack, 1);
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
	my $max_hits         = $is_novice ? $self->{config}{NOVICE_MAX_ESTIMATED_HITS}  : $self->{config}{MAX_ESTIMATED_HITS};

	push @reasons, 'MVP excluded' if $monster->{is_mvp};
	push @reasons, 'boss spawn excluded' if _boss_on_map($monster, $map);
	push @reasons, "monster level is more than $max_level_above above character"
		if $diff > $max_level_above;
	push @reasons, "monster level is more than $self->{config}{MAX_LEVEL_BELOW} below character"
		if $diff < -$self->{config}{MAX_LEVEL_BELOW};

	push @reasons, 'novice: monster attack exceeds novice limit'
		if $is_novice && $attack_max > $self->{config}{NOVICE_MAX_MONSTER_ATTACK};

	my ($hits) = _estimated_hits($snapshot, $monster);
	push @reasons, $is_novice ? 'novice: estimated kill cost is too high' : 'estimated kill cost is extreme'
		if $hits > $max_hits;
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

sub _target_risk {
	my ($self, $snapshot, $monster) = @_;
	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $hp_max = max(1, _num($snapshot->{hp_max}, 1));
	my $attack_max = max(_num($monster->{attack}, 0), _num($monster->{attack2}, 0));
	my $attack_ratio = $attack_max / $hp_max;
	my ($hits) = _estimated_hits($snapshot, $monster);
	my $range = _num($monster->{attack_range}, 1);

	my $risk = max(0, $diff - 2) * 1.5;
	$risk += max(0, $attack_ratio - 0.08) * 20;
	$risk += $hits > 12 ? log($hits / 12) * 5 : 0;
	$risk += min(8, max(0, $range - 1) * $self->{config}{RANGED_RISK_WEIGHT});
	$risk += 4 if $diff > 4 && $attack_ratio > 0.20;
	$risk *= $self->{config}{NOVICE_TARGET_RISK_MULTIPLIER} if _is_novice($snapshot);
	return min(30, max(0, $risk));
}

sub _map_danger {
	my ($self, $snapshot, $monster, $map, $spawn_count) = @_;
	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $hp_max = max(1, _num($snapshot->{hp_max}, 1));
	my $attack_max = max(_num($monster->{attack}, 0), _num($monster->{attack2}, 0));
	my $attack_ratio = $attack_max / $hp_max;
	my ($hits) = _estimated_hits($snapshot, $monster);
	my $range = _num($monster->{attack_range}, 1);

	my $danger = 0;
	$danger += 35 if $monster->{is_mvp} || _boss_on_map($monster, $map);
	$danger += max(0, $diff - 2) * 1.2;
	$danger += max(0, $attack_ratio - 0.12) * 18;
	$danger += $hits > 20 ? log($hits / 20) * 5 : 0;
	$danger += min(6, max(0, $range - 1));

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

	my $diff = _num($monster->{level}, 0) - _num($snapshot->{base_level}, 0);
	my $level_fit = _level_fit($diff) * $self->{config}{LEVEL_FIT_WEIGHT};
	my $total_exp = max(0, _num($monster->{base_exp}, 0) + _num($monster->{job_exp}, 0));
	my $exp_value = min(24, log(1 + $total_exp) * 3.5) * $self->{config}{EXP_WEIGHT};
	my $spawn_score = min(18, log(1 + max(0, _num($spawn_count, 0))) * 4)
		* $self->{config}{SPAWN_COUNT_WEIGHT};
	my ($hits, $degraded_attack) = _estimated_hits($snapshot, $monster);
	my $kill_cost = min(22, log(1 + max(0, $hits)) * 5) * $self->{config}{KILL_COST_WEIGHT};
	my $target_risk = $self->_target_risk($snapshot, $monster) * $self->{config}{TARGET_RISK_WEIGHT};

	my $own_map_risk = $map_profile->{contributions}{$monster->{id}}{weighted} // 0;
	my $map_risk = min(35, max(0, ($map_profile->{total} // 0) - $own_map_risk))
		* $self->{config}{MAP_RISK_WEIGHT};
	my $score = $level_fit + $exp_value + $spawn_score - $kill_cost - $target_risk - $map_risk;

	my @reasons;
	push @reasons, 'monster level close to character' if abs($diff) <= 2;
	push @reasons, 'high spawn count' if $spawn_count >= 40;
	push @reasons, 'good static EXP value' if $exp_value >= 14;
	push @reasons, 'ranged basic attack' if _num($monster->{attack_range}, 1) > 1;
	push @reasons, 'dangerous co-spawns on map' if $map_risk >= 5;
	push @reasons, 'kill cost uses level-based fallback attack' if $degraded_attack;

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
			kill_cost        => $kill_cost,
			target_risk      => $target_risk,
			map_risk         => $map_risk,
		},
		reasons => \@reasons,
		estimated_hits => $hits,
		travel_cost => undef,
		route_reachability => 'UNVERIFIED',
	};
}

1;
