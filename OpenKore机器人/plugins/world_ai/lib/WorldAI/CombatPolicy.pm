package WorldAI::CombatPolicy;

use strict;
use warnings;

use WorldAI::ClassProfile;

sub new { return bless {}, $_[0] }

sub _trim {
	my ($value) = @_;
	$value //= '';
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub class_family {
	my ($self, %args) = @_;
	return WorldAI::ClassProfile::class_family(%args);
}

sub evaluate {
	my ($self, %args) = @_;
	my $family = $self->class_family(job_id => $args{job_id}, job_name => $args{job_name});
	my $target_name = _trim($args{target_monster_name});
	my $target_id = $args{target_monster_id};
	my @skills;

	my $state = WorldAI::ClassProfile::baseline_skill_state(
		family               => $family,
		known_skills         => $args{known_skills},
		attack_skill_slots   => $args{attack_skill_slots},
		target_monster_name  => $target_name,
		target_monster_id    => $target_id,
	);
	if ($state) {
		push @skills, {
			skill_handle => $state->{handle},
			known_level  => $state->{known_level},
			enabled      => $state->{enabled},
			reason       => $state->{reason},
			slots        => $state->{slots},
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
