package WorldAI::CombatRuntimeOverride;

use strict;
use warnings;

sub new {
	my ($class, %args) = @_;
	die 'config hash is required' unless ref($args{config}) eq 'HASH';
	return bless {
		config => $args{config},
		active => 0,
	}, $class;
}

sub active { return $_[0]{active} ? 1 : 0 }

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

sub apply {
	my ($self, %args) = @_;
	die 'combat runtime override is already active' if $self->{active};
	my $policy = $args{policy};
	die 'combat policy hash is required' unless ref($policy) eq 'HASH';
	my $target = _trim($policy->{target_monster_name});
	die 'target monster is required' if $target eq '';
	die 'target monster contains an invalid delimiter' if $target =~ /[,\r\n]/;

	my $config = $self->{config};
	my (@saved, @overrides);
	my %seen;
	for my $skill (@{ref($policy->{skills}) eq 'ARRAY' ? $policy->{skills} : []}) {
		next unless $skill->{enabled};
		for my $slot (@{ref($skill->{slots}) eq 'ARRAY' ? $skill->{slots} : []}) {
			die 'invalid attack skill slot index' unless defined($slot) && $slot =~ /^\d+$/;
			next if $seen{$slot}++;
			my $slot_key = "attackSkillSlot_$slot";
			die "attack skill slot $slot is unavailable" unless defined($config->{$slot_key}) && $config->{$slot_key} ne '';
			my $key = "${slot_key}_monsters";
			my $existed = exists($config->{$key}) ? 1 : 0;
			my $original = $config->{$key};
			my $changed = 0;
			my $applied = $original;

			# An empty monsters condition already allows every target. Restricting it
			# would change the original slot semantics, so leave it untouched.
			if (defined($original) && _trim($original) ne '' &&
				!_list_contains($original, $target, $policy->{target_monster_id})) {
				$applied = _trim($original) . ', ' . $target;
				$changed = 1;
			}
			push @saved, { key => $key, existed => $existed, value => $original } if $changed;
			push @overrides, {
				slot => 0 + $slot,
				skill_handle => $skill->{skill_handle},
				key => $key,
				original_filter => $original,
				applied_filter => $applied,
				changed => $changed,
			};
		}
	}

	for my $change (@overrides) {
		$config->{$change->{key}} = $change->{applied_filter} if $change->{changed};
	}
	$self->{saved} = \@saved;
	$self->{overrides} = \@overrides;
	$self->{policy} = $policy;
	$self->{active} = 1;
	return 1;
}

sub overrides {
	my ($self) = @_;
	return [map { { %$_ } } @{$self->{overrides} || []}];
}

sub restore {
	my ($self) = @_;
	return 0 unless $self->{active};
	my $config = $self->{config};
	for my $saved (@{$self->{saved} || []}) {
		if ($saved->{existed}) {
			$config->{$saved->{key}} = $saved->{value};
		} else {
			delete $config->{$saved->{key}};
		}
	}
	delete @{$self}{qw(saved overrides policy)};
	$self->{active} = 0;
	return 1;
}

1;
