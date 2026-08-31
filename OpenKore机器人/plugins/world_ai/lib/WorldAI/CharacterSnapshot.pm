package WorldAI::CharacterSnapshot;

use strict;
use warnings;

use Globals qw($char $field $net %jobs_lut);
use Network;
use Scalar::Util qw(looks_like_number);

sub _number {
	my ($value) = @_;
	return undef unless defined $value && looks_like_number($value);
	return 0 + $value;
}

sub _sum_defined {
	my (@values) = @_;
	my $seen = 0;
	my $sum = 0;
	for my $value (@values) {
		next unless defined $value;
		$sum += $value;
		$seen = 1;
	}
	return $seen ? $sum : undef;
}

sub capture {
	return (undef, 'not in game')
		unless $net && $net->getState() == Network::IN_GAME && $char;

	my $base_level = _number($char->{lv});
	return (undef, 'base level is unavailable') unless defined $base_level && $base_level > 0;

	my $attack = _number($char->{attack});
	my $attack_bonus = _number($char->{attack_bonus});
	my $defense = _number($char->{def});
	my $defense_bonus = _number($char->{def_bonus});
	my $map = eval { $field ? $field->baseName : undef };
	my $pos_x = _number($char->{pos_to}{x});
	my $pos_y = _number($char->{pos_to}{y});

	return ({
		base_level    => $base_level,
		job_level     => _number($char->{lv_job}),
		job_id        => _number($char->{jobID}),
		job_name      => defined($char->{jobID}) ? ($jobs_lut{$char->{jobID}} // "Class $char->{jobID}") : undef,
		hp            => _number($char->{hp}),
		hp_max        => _number($char->{hp_max}),
		sp            => _number($char->{sp}),
		sp_max        => _number($char->{sp_max}),
		current_map   => $map,
		pos_x         => $pos_x,
		pos_y         => $pos_y,
		zeny          => _number($char->{zeny}),
		attack        => $attack,
		attack_bonus  => $attack_bonus,
		attack_total  => _sum_defined($attack, $attack_bonus),
		attack_range  => _number($char->{attack_range}),
		defense       => $defense,
		defense_bonus => $defense_bonus,
		defense_total => _sum_defined($defense, $defense_bonus),
		hit           => _number($char->{hit}),
		flee          => _number($char->{flee}),
	}, undef);
}

1;
