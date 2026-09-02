package WorldAI::CombatPolicy;

use strict;
use warnings;

my %JOB_FAMILY = (
	THIEF_FAMILY => { map { $_ => 1 } qw(6 12 17 167 173 178 4007 4013 4018 4029 4035 4040 4059 4065) },
	SWORDMAN_FAMILY => { map { $_ => 1 } qw(1 7 13 14 21 162 168 174 175 4002 4008 4014 4015 4024 4030 4036 4037 4054 4060) },
	MAGE_FAMILY => { map { $_ => 1 } qw(2 9 16 163 170 177 4003 4010 4017 4025 4032 4039 4055 4061) },
	ARCHER_FAMILY => { map { $_ => 1 } qw(3 11 19 20 164 172 180 181 4004 4012 4020 4021 4026 4034 4042 4043 4056 4062) },
	ACOLYTE_FAMILY => { map { $_ => 1 } qw(4 8 15 165 169 176 4005 4009 4016 4027 4031 4038 4057 4063) },
);

my %BASELINE_SKILL = (
	SWORDMAN_FAMILY => 'SM_BASH',
	MAGE_FAMILY     => 'MG_FIREBOLT',
	ARCHER_FAMILY   => 'AC_DOUBLE',
	ACOLYTE_FAMILY  => 'AL_HOLYLIGHT',
);

sub new { return bless {}, $_[0] }

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

sub class_family {
	my ($self, %args) = @_;
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

sub _known_level {
	my ($known, $handle) = @_;
	return 0 unless ref($known) eq 'HASH' && exists $known->{$handle};
	my $value = $known->{$handle};
	return 0 + ($value->{lv} || 0) if ref($value) eq 'HASH';
	return 0 + ($value || 0);
}

sub evaluate {
	my ($self, %args) = @_;
	my $family = $self->class_family(job_id => $args{job_id}, job_name => $args{job_name});
	my $target_name = _trim($args{target_monster_name});
	my $target_id = $args{target_monster_id};
	my $handle = $BASELINE_SKILL{$family};
	my @skills;

	if ($handle) {
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
		push @skills, {
			skill_handle => $handle,
			known_level  => $known_level,
			enabled      => $enabled,
			reason       => $reason,
			slots        => [map { 0 + $_->{index} } @eligible],
		};
	}

	my $has_enabled = grep { $_->{enabled} } @skills;
	return {
		class_family          => $family,
		target_monster_id     => $target_id,
		target_monster_name   => $target_name,
		target_map            => $args{target_map},
		mode                  => $has_enabled ? 'SINGLE_TARGET' : 'NORMAL_ATTACK_BASELINE',
		skills                => \@skills,
		fallback_normal_attack => 1,
	};
}

1;
