package WorldAI::CombatEstimate;

use strict;
use warnings;

use List::Util qw(max min);
use Scalar::Util qw(looks_like_number);

use WorldAI::ClassProfile;

# 静态“战斗代理值”配置。只要求方向正确、可解释、可测试、可降级，不是完整伤害公式。
my %DEFAULTS = (
	PHYSICAL_FALLBACK_PER_LEVEL => 5,
	MAGIC_FALLBACK_PER_LEVEL    => 4,
	DEFENSE_PENALTY_DIVISOR     => 20,   # DEF/MDEF 每 20 点 → 1.0 惩罚
	DEFENSE_PENALTY_CAP         => 4.0,
	SKILL_MULT_SM_BASH          => 0.12, # 每级 +12%，SP 缩放
	SKILL_MULT_AC_DOUBLE        => 0.25, # 每级 +25%，SP 缩放
	SKILL_MULT_MG_FIREBOLT      => 0.20, # 每级 +20%，SP 缩放
	SKILL_MULT_AL_HOLYLIGHT     => 1.50, # 固定约 1.5×，SP 缩放
	TF_DOUBLE_EXPECTED_MULT     => 0.5,  # Lv10 期望输出 +50%（永不常驻翻倍）
	SP_FACTOR_KNEE              => 0.3,  # SP≥30% 时技能加成全额生效
);

sub new {
	my ($class, %args) = @_;
	my %config = (%DEFAULTS, %{$args{config} || {}});
	return bless { config => \%config }, $class;
}

sub _num {
	my ($value, $default) = @_;
	return $default unless defined $value && looks_like_number($value);
	return 0 + $value;
}

sub _known_level {
	my ($known, $handle) = @_;
	return 0 unless ref($known) eq 'HASH' && exists $known->{$handle};
	my $value = $known->{$handle};
	return 0 + ($value->{lv} || 0) if ref($value) eq 'HASH';
	return 0 + ($value || 0);
}

sub _sp_factor {
	my ($self, $snapshot) = @_;
	my $sp = _num($snapshot->{sp}, 0);
	my $sp_max = _num($snapshot->{sp_max}, 0);
	return 1.0 unless $sp_max > 0;
	return min(1.0, ($sp / $sp_max) / $self->{config}{SP_FACTOR_KNEE});
}

sub _skill_mult {
	my ($self, $handle, $level, $snapshot) = @_;
	my $sp_factor = $self->_sp_factor($snapshot);
	return 1 + $self->{config}{SKILL_MULT_SM_BASH} * $level * $sp_factor if $handle eq 'SM_BASH';
	return 1 + $self->{config}{SKILL_MULT_AC_DOUBLE} * $level * $sp_factor if $handle eq 'AC_DOUBLE';
	return 1 + $self->{config}{SKILL_MULT_MG_FIREBOLT} * $level * $sp_factor if $handle eq 'MG_FIREBOLT';
	return $self->{config}{SKILL_MULT_AL_HOLYLIGHT} * $sp_factor if $handle eq 'AL_HOLYLIGHT';
	return 1.0;
}

sub _defense_penalty {
	my ($self, $damage_type, $monster) = @_;
	my $def = $damage_type eq 'MAGIC'
		? _num($monster->{magic_defense}, 0)
		: _num($monster->{defense}, 0);
	return min($self->{config}{DEFENSE_PENALTY_CAP},
		max(0, $def) / $self->{config}{DEFENSE_PENALTY_DIVISOR});
}

sub _element_factor {
	my ($self, $attacker_element, $monster, $element_table) = @_;
	return 1.0 unless $attacker_element && ref($element_table) eq 'HASH';
	my $target = $monster->{element};
	my $level = $monster->{element_level};
	return 1.0 unless defined($target) && defined($level) && $target ne '';
	my $lvl = $element_table->{"$level"} || $element_table->{$level};
	return 1.0 unless ref($lvl) eq 'HASH';
	my $outer = $lvl->{$attacker_element};
	return 1.0 unless ref($outer) eq 'HASH';
	return 1.0 unless exists $outer->{$target};
	my $value = _num($outer->{$target}, undef);
	return 1.0 unless defined $value;
	return $value / 100;
}

sub estimate {
	my ($self, %args) = @_;
	my $snapshot = $args{snapshot} || {};
	my $monster = $args{monster} || {};
	my $profile = $args{profile} || {};
	my $skill_state = $args{skill_state};
	my $known_skills = $args{known_skills} || {};
	my $element_table = $args{element_table};
	my $archer_has_ammo = defined($args{archer_has_ammo}) ? $args{archer_has_ammo} : 1;

	my $damage_type = $profile->{primary_damage} || 'PHYSICAL';
	my $combat_style = $profile->{combat_style} || 'MELEE';
	my @reasons;
	my $degraded = 0;
	my ($estimate_mode, $source, $skill_level, $raw_power, $skill_mult);

	# 基线主动技能是否实际可用（已学 + 有槽 + 未被 notMonsters 排除）。
	my ($use_skill, $skill_handle) = (0, undef);
	$skill_level = 0;
	if ($skill_state && $skill_state->{enabled}) {
		$use_skill = 1;
		$skill_handle = $skill_state->{handle};
		$skill_level = _num($skill_state->{known_level}, 0);
	}
	# Archer 无箭时 Double Strafe 不可用，不能据此高估。
	if ($use_skill && $skill_handle && $skill_handle eq 'AC_DOUBLE' && !$archer_has_ammo) {
		push @reasons, 'Double Strafe unavailable: no arrows';
		($use_skill, $skill_handle, $skill_level) = (0, undef, 0);
		$degraded = 1;
	}

	if ($damage_type eq 'MAGIC') {
		if ($use_skill && $skill_handle) {
			my $matk = _num($snapshot->{attack_magic_avg}, undef);
			if (defined($matk) && $matk > 0) {
				$estimate_mode = 'MAGIC_SKILL';
				$raw_power = $matk;
				push @reasons, 'using MATK proxy';
			} else {
				# Degraded：拿不到 MATK 时用等级代理，绝不退回法杖物攻。
				$estimate_mode = 'MAGIC_DEGRADED';
				$raw_power = max(20, _num($snapshot->{base_level}, 1) * $self->{config}{MAGIC_FALLBACK_PER_LEVEL});
				$degraded = 1;
				push @reasons, 'MATK unavailable, using level-based magic proxy';
			}
			$source = $skill_handle;
			$skill_mult = $self->_skill_mult($skill_handle, $skill_level, $snapshot);
			push @reasons, "$skill_handle baseline active";
		} else {
			# 魔法职业没有可用技能 → 退化为普攻，伤害类型也随之变为物理。
			$estimate_mode = 'PHYSICAL_NORMAL';
			$source = 'normal_attack';
			$damage_type = 'PHYSICAL';
			$skill_mult = 1.0;
			my $atk = _num($snapshot->{attack_total}, undef);
			if (defined($atk) && $atk > 0) {
				$raw_power = $atk;
			} else {
				$raw_power = max(20, _num($snapshot->{base_level}, 1) * $self->{config}{PHYSICAL_FALLBACK_PER_LEVEL});
				$degraded = 1;
				push @reasons, 'attack unavailable, using level-based fallback';
			}
			push @reasons, 'baseline magic skill unavailable, using normal attack';
		}
	} else {
		my $atk = _num($snapshot->{attack_total}, undef);
		if (defined($atk) && $atk > 0) {
			$raw_power = $atk;
		} else {
			$raw_power = max(20, _num($snapshot->{base_level}, 1) * $self->{config}{PHYSICAL_FALLBACK_PER_LEVEL});
			$degraded = 1;
			push @reasons, 'attack unavailable, using level-based fallback';
		}

		if ($use_skill && $skill_handle) {
			$estimate_mode = 'PHYSICAL_SKILL';
			$source = $skill_handle;
			$skill_mult = $self->_skill_mult($skill_handle, $skill_level, $snapshot);
			push @reasons, "$skill_handle baseline active";
		} else {
			$estimate_mode = 'PHYSICAL_NORMAL';
			$source = 'normal_attack';
			$skill_mult = 1.0;
		}

		# Thief 被动 Double Attack：期望输出加成（Lv10 ≈ +50%），不是每击必翻倍。
		my $passive = $profile->{passive_skill};
		if ($passive && $passive eq 'TF_DOUBLE') {
			my $passive_level = _known_level($known_skills, 'TF_DOUBLE');
			if ($passive_level > 0) {
				my $expected_mult = min(1.5,
					1 + $self->{config}{TF_DOUBLE_EXPECTED_MULT} * ($passive_level / 10));
				$skill_mult *= $expected_mult;
				push @reasons, "TF_DOUBLE passive Lv$passive_level applied";
			}
		}
	}

	# 元素克制必须作用到伤害本身（进而影响 kill_cost），不能只作为评分提示：
	# Fire 打 Fire（25%）应显著抬高 kill_cost，Fire 打 Earth（150%）应显著压低。
	my $element_factor = 1.0;
	if ($damage_type eq 'MAGIC' && $profile->{baseline_element}) {
		$element_factor = $self->_element_factor($profile->{baseline_element}, $monster, $element_table);
	}
	push @reasons, 'target element favorable' if $element_factor > 1.05;
	push @reasons, 'target element unfavorable' if $element_factor < 0.95;

	my $effective_power = max(1, $raw_power * $skill_mult * $element_factor);
	my $estimated_kill_cost = _num($monster->{hp}, 0) / $effective_power;
	my $defense_penalty = $self->_defense_penalty($damage_type, $monster);
	push @reasons, $damage_type eq 'MAGIC' ? 'high monster MDEF' : 'high monster DEF'
		if $defense_penalty >= 1.5;

	return {
		estimate_mode        => $estimate_mode,
		damage_type          => $damage_type,
		combat_style         => $combat_style,
		source               => $source,
		skill_level          => $skill_level,
		raw_power            => $raw_power,
		effective_power      => $effective_power,
		defense_penalty      => $defense_penalty,
		element_factor       => $element_factor,
		estimated_kill_cost  => $estimated_kill_cost,
		degraded             => $degraded ? 1 : 0,
		reasons              => \@reasons,
	};
}

1;
