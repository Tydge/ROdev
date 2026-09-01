package WorldAI::RuntimeOverride;

use strict;
use warnings;

my @CONFIG_KEYS = qw(
	lockMap lockMap_x lockMap_y lockMap_randX lockMap_randY
	route_maxWarpFee route_warpByItem saveMap_warp
);

sub new {
	my ($class, %args) = @_;
	die 'config hash is required' unless ref($args{config}) eq 'HASH';
	die 'mon_control hash is required' unless ref($args{mon_control}) eq 'HASH';
	return bless {
		config      => $args{config},
		mon_control => $args{mon_control},
		active      => 0,
	}, $class;
}

sub active { return $_[0]{active} ? 1 : 0 }

sub apply {
	my ($self, %args) = @_;
	die 'runtime override is already active' if $self->{active};
	my $map = $args{target_map};
	my $monster = $args{monster};
	die 'target map is required' unless defined($map) && $map ne '';
	die 'target monster is required' unless defined($monster) && $monster ne '';

	my $config = $self->{config};
	my $controls = $self->{mon_control};
	my %saved_config;
	for my $key (@CONFIG_KEYS) {
		$saved_config{$key} = {
			existed => exists($config->{$key}) ? 1 : 0,
			value   => $config->{$key},
		};
	}

	my $monster_key = lc $monster;
	my $monster_existed = exists $controls->{$monster_key};
	my $saved_monster = $monster_existed
		? { %{$controls->{$monster_key} || {}} }
		: undef;
	my $fallback = $controls->{$monster_key} || $controls->{all} || {};

	$self->{saved_config} = \%saved_config;
	$self->{monster_key} = $monster_key;
	$self->{monster_existed} = $monster_existed;
	$self->{saved_monster} = $saved_monster;
	$self->{active} = 1;

	# Direct hash assignment is intentional: configModify writes config.txt.
	$config->{lockMap} = $map;
	$config->{lockMap_x} = '';
	$config->{lockMap_y} = '';
	$config->{lockMap_randX} = '';
	$config->{lockMap_randY} = '';
	$config->{route_maxWarpFee} = 0;
	$config->{route_warpByItem} = 0;
	$config->{saveMap_warp} = 0;
	$controls->{$monster_key} = {
		%{$fallback},
		attack_auto => 1,
	};

	return 1;
}

sub restore {
	my ($self) = @_;
	return 0 unless $self->{active};

	my $config = $self->{config};
	for my $key (@CONFIG_KEYS) {
		my $saved = $self->{saved_config}{$key};
		if ($saved->{existed}) {
			$config->{$key} = $saved->{value};
		} else {
			delete $config->{$key};
		}
	}

	my $controls = $self->{mon_control};
	if ($self->{monster_existed}) {
		$controls->{$self->{monster_key}} = $self->{saved_monster};
	} else {
		delete $controls->{$self->{monster_key}};
	}

	delete @{$self}{qw(saved_config monster_key monster_existed saved_monster)};
	$self->{active} = 0;
	return 1;
}

1;
