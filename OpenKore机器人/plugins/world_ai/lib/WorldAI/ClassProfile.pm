package WorldAI::ClassProfile;

use strict;
use warnings;

# 职业族 ID 表（权威）。名字是兼容回退。与 CombatPolicy 共享，避免两处漂移。
my %JOB_FAMILY = (
	THIEF_FAMILY => { map { $_ => 1 } qw(6 12 17 167 173 178 4007 4013 4018 4029 4035 4040 4059 4065) },
	SWORDMAN_FAMILY => { map { $_ => 1 } qw(1 7 13 14 21 162 168 174 175 4002 4008 4014 4015 4024 4030 4036 4037 4054 4060) },
	MAGE_FAMILY => { map { $_ => 1 } qw(2 9 16 163 170 177 4003 4010 4017 4025 4032 4039 4055 4061) },
	ARCHER_FAMILY => { map { $_ => 1 } qw(3 11 19 20 164 172 180 181 4004 4012 4020 4021 4026 4034 4042 4043 4056 4062) },
	ACOLYTE_FAMILY => { map { $_ => 1 } qw(4 8 15 165 169 176 4005 4009 4016 4027 4031 4038 4057 4063) },
);

# 第一版职业 Profile。这些只是“方向正确”的战斗代理值，不是完整伤害公式。
my %FAMILY_PROFILE = (
	THIEF_FAMILY => {
		primary_damage  => 'PHYSICAL',
		combat_style    => 'MELEE',
		baseline_skill  => undef,
		baseline_element => undef,
		passive_skill   => 'TF_DOUBLE',
	},
	SWORDMAN_FAMILY => {
		primary_damage  => 'PHYSICAL',
		combat_style    => 'MELEE',
		baseline_skill  => 'SM_BASH',
		baseline_element => undef,
		passive_skill   => undef,
	},
	MAGE_FAMILY => {
		primary_damage  => 'MAGIC',
		combat_style    => 'RANGED_CAST',
		baseline_skill  => 'MG_FIREBOLT',
		baseline_element => 'Fire',
		passive_skill   => undef,
	},
	ARCHER_FAMILY => {
		primary_damage  => 'PHYSICAL',
		combat_style    => 'RANGED',
		baseline_skill  => 'AC_DOUBLE',
		baseline_element => undef,
		passive_skill   => undef,
	},
	ACOLYTE_FAMILY => {
		primary_damage  => 'MAGIC',
		combat_style    => 'RANGED_CAST',
		baseline_skill  => 'AL_HOLYLIGHT',
		baseline_element => 'Holy',
		passive_skill   => undef,
	},
);

sub _trim {
	my ($value) = @_;
	$value //= '';
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub _list_contains {
	my ($list, @values) = @_;
	return 0 unless defined($list) && _trim($list) ne '';
	my %wanted = map { lc(_trim($_)) => 1 } grep { defined($_) && _trim($_) ne '' } @values;
	for my $entry (split /\s*,\s*/, $list) {
		return 1 if $wanted{lc(_trim($entry))};
	}
	return 0;
}

sub _known_level {
	my ($known, $handle) = @_;
	return 0 unless ref($known) eq 'HASH' && exists $known->{$handle};
	my $value = $known->{$handle};
	return 0 + ($value->{lv} || 0) if ref($value) eq 'HASH';
	return 0 + ($value || 0);
}

sub class_family {
	my (%args) = @_;
	my $job_id = $args{job_id};
	if (defined($job_id) && $job_id =~ /^\d+$/) {
		for my $family (qw(THIEF_FAMILY SWORDMAN_FAMILY MAGE_FAMILY ARCHER_FAMILY ACOLYTE_FAMILY)) {
			return $family if $JOB_FAMILY{$family}{$job_id};
		}
	}

	# The ID table is authoritative. Names are only a compatibility fallback for
	# servers which use custom job IDs but retain OpenKore's English job names.
	my $name = lc _trim($args{job_name});
	return 'THIEF_FAMILY' if $name =~ /(?:thief|assassin|rogue|glt\.? cross|guillotine cross|shadow chaser)/;
	return 'SWORDMAN_FAMILY' if $name =~ /(?:swordsman|swordman|knight|crusader|paladin|royal guard)/;
	return 'MAGE_FAMILY' if $name =~ /(?:mage|magician|wizard|sage|professor|warlock|sorcerer)/;
	return 'ARCHER_FAMILY' if $name =~ /(?:archer|hunter|bard|dancer|sniper|clown|gypsy|ranger|maestro|wanderer)/;
	return 'ACOLYTE_FAMILY' if $name =~ /(?:acolyte|priest|monk|champion|arch bishop|sura)/;
	return 'UNSUPPORTED';
}

sub profile {
	my ($family) = @_;
	return undef unless defined($family) && exists $FAMILY_PROFILE{$family};
	return { %{$FAMILY_PROFILE{$family}} };
}

sub baseline_skill  { my ($f) = @_; my $p = profile($f); return $p ? $p->{baseline_skill} : undef; }
sub damage_type     { my ($f) = @_; my $p = profile($f); return $p ? $p->{primary_damage} : 'PHYSICAL'; }
sub baseline_element { my ($f) = @_; my $p = profile($f); return $p ? $p->{baseline_element} : undef; }
sub combat_style    { my ($f) = @_; my $p = profile($f); return $p ? $p->{combat_style} : 'MELEE'; }
sub passive_skill   { my ($f) = @_; my $p = profile($f); return $p ? $p->{passive_skill} : undef; }

# 判断基线技能对某个目标是否“实际可用”：已学 + 有对应 attackSkillSlot +
# 未被 notMonsters 明确排除。返回 undef 表示该职业族没有主动基线技能。
sub baseline_skill_state {
	my (%args) = @_;
	my $family = $args{family};
	my $handle = baseline_skill($family);
	return undef unless $handle;

	my $target_name = _trim($args{target_monster_name});
	my $target_id = $args{target_monster_id};
	my $known_level = _known_level($args{known_skills}, $handle);
	my @configured = grep {
		uc(_trim($_->{handle})) eq $handle
	} @{ref($args{attack_skill_slots}) eq 'ARRAY' ? $args{attack_skill_slots} : []};
	my @eligible = grep {
		!_list_contains($_->{not_monsters}, $target_name, $target_id)
	} @configured;

	my ($enabled, $reason) = (0, 'executed_target_unavailable');
	if (!$known_level) {
		$reason = 'skill_not_learned';
	} elsif (!@configured) {
		$reason = 'configured_attack_slot_missing';
	} elsif ($target_name eq '') {
		$reason = 'executed_target_unavailable';
	} elsif (!@eligible) {
		$reason = 'target_blocked_by_notMonsters';
	} else {
		$enabled = 1;
		$reason = 'baseline_single_target_skill';
	}

	return {
		handle      => $handle,
		known_level => $known_level,
		enabled     => $enabled,
		reason      => $reason,
		slots       => [map { 0 + $_->{index} } @eligible],
	};
}

1;
