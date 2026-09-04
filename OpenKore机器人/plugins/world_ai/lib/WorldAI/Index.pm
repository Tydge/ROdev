package WorldAI::Index;

use strict;
use warnings;

use JSON::PP qw(decode_json);
use Scalar::Util qw(looks_like_number);

our $SUPPORTED_SCHEMA = 3;

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		path       => $args{path},
		state      => undef,
		last_error => undef,
	}, $class;
	return $self;
}

sub reload {
	my ($self) = @_;
	my ($state, $error) = $self->_read_state($self->{path});
	if (!$state) {
		$self->{last_error} = $error;
		return (0, $error);
	}

	# Atomic from the caller's point of view: the previous state remains available
	# until the replacement has been completely parsed, validated, and indexed.
	$self->{state} = $state;
	$self->{last_error} = undef;
	return (1, undef);
}

sub _read_state {
	my ($self, $path) = @_;
	return (undef, 'index path is empty') unless defined $path && length $path;

	my $raw;
	if (!open my $fh, '<:raw', $path) {
		return (undef, "cannot open index: $!");
	} else {
		local $/;
		$raw = <$fh>;
		close $fh;
	}

	my $doc = eval { decode_json($raw) };
	if (!$doc || $@) {
		my $error = $@ || 'decoded JSON is empty';
		$error =~ s/\s+/ /g;
		return (undef, "invalid JSON: $error");
	}
	return (undef, 'index root must be an object') unless ref $doc eq 'HASH';

	my $meta = $doc->{meta};
	return (undef, 'index meta is missing') unless ref $meta eq 'HASH';
	my $schema = $meta->{schema_version};
	return (undef, 'schema_version is missing') unless defined $schema;
	return (undef, "unsupported schema_version=$schema expected=$SUPPORTED_SCHEMA")
		unless looks_like_number($schema) && int($schema) == $SUPPORTED_SCHEMA;

	my $monsters = $doc->{monsters};
	my $maps = $doc->{maps};
	my $element_table = $doc->{element_table};
	return (undef, 'monsters must be an object') unless ref $monsters eq 'HASH';
	return (undef, 'maps must be an object') unless ref $maps eq 'HASH';
	return (undef, 'element_table must be an object') unless ref $element_table eq 'HASH';

	my (%by_name, %by_aegis);
	my $pair_count = 0;
	for my $id (keys %{$monsters}) {
		my $monster = $monsters->{$id};
		return (undef, "monster $id must be an object") unless ref $monster eq 'HASH';
		for my $key (qw(id name aegis_name level hp base_exp job_exp attack attack2 maps mode)) {
			return (undef, "monster $id missing $key") unless exists $monster->{$key};
		}
		return (undef, "monster key/id mismatch for $id")
			unless looks_like_number($monster->{id}) && int($monster->{id}) == int($id);
		return (undef, "monster $id maps must be an object") unless ref $monster->{maps} eq 'HASH';
		return (undef, "monster $id mode must be an object") unless ref $monster->{mode} eq 'HASH';

		push @{$by_name{lc($monster->{name} // '')}}, int($id) if length($monster->{name} // '');
		push @{$by_aegis{lc($monster->{aegis_name} // '')}}, int($id) if length($monster->{aegis_name} // '');
		$pair_count += scalar keys %{$monster->{maps}};
	}

	for my $map (keys %{$maps}) {
		return (undef, "map $map spawns must be an object") unless ref $maps->{$map} eq 'HASH';
		for my $id (keys %{$maps->{$map}}) {
			return (undef, "map $map references unknown monster $id") unless exists $monsters->{$id};
			return (undef, "map $map monster $id has invalid spawn count")
				unless looks_like_number($maps->{$map}{$id}) && $maps->{$map}{$id} >= 0;
		}
	}

	for my $lookup (\%by_name, \%by_aegis) {
		for my $key (keys %{$lookup}) {
			@{$lookup->{$key}} = sort { $a <=> $b } @{$lookup->{$key}};
		}
	}

	return ({
		doc           => $doc,
		by_name       => \%by_name,
		by_aegis      => \%by_aegis,
		pair_count    => $pair_count,
		element_table => $element_table,
	}, undef);
}

sub loaded       { return defined $_[0]->{state}; }
sub path         { return $_[0]->{path}; }
sub last_error   { return $_[0]->{last_error}; }
sub schema       { return $_[0]->loaded ? $_[0]->{state}{doc}{meta}{schema_version} : undef; }
sub meta         { return $_[0]->loaded ? $_[0]->{state}{doc}{meta} : undef; }
sub monster_count { return $_[0]->loaded ? scalar(keys %{$_[0]->{state}{doc}{monsters}}) : 0; }
sub map_count     { return $_[0]->loaded ? scalar(keys %{$_[0]->{state}{doc}{maps}}) : 0; }
sub pair_count    { return $_[0]->loaded ? $_[0]->{state}{pair_count} : 0; }

sub monster_ids {
	my ($self) = @_;
	return () unless $self->loaded;
	return sort { $a <=> $b } map { int($_) } keys %{$self->{state}{doc}{monsters}};
}

sub monster {
	my ($self, $id) = @_;
	return undef unless $self->loaded && defined $id && $id =~ /^\d+$/;
	return $self->{state}{doc}{monsters}{int($id)};
}

sub mode {
	my ($self, $id) = @_;
	return undef unless $self->loaded && defined $id && $id =~ /^\d+$/;
	my $monster = $self->{state}{doc}{monsters}{int($id)};
	return undef unless $monster;
	return $monster->{mode};
}

sub element_table { return $_[0]->loaded ? $_[0]->{state}{element_table} : undef; }

# 元素克制倍率（百分比）：攻击元素 × 目标防御元素 × 目标元素等级。
# 返回数值百分比（如 150 表示 1.5×，50 表示 0.5×），缺失时返回 undef。
sub element_factor {
	my ($self, $attacker, $target, $level) = @_;
	return undef unless $self->loaded && defined($attacker) && defined($target) && defined($level);
	my $table = $self->{state}{element_table};
	my $lvl = $table->{"$level"} || $table->{$level};
	return undef unless ref($lvl) eq 'HASH';
	my $outer = $lvl->{$attacker};
	return undef unless ref($outer) eq 'HASH';
	return undef unless exists $outer->{$target};
	return $outer->{$target};
}

sub map_spawns {
	my ($self, $map) = @_;
	return undef unless $self->loaded && defined $map;
	return $self->{state}{doc}{maps}{$map};
}

sub find_monsters {
	my ($self, $query) = @_;
	return () unless $self->loaded && defined $query;
	$query =~ s/^\s+|\s+$//g;
	return () unless length $query;

	if ($query =~ /^\d+$/) {
		my $monster = $self->monster($query);
		return $monster ? ($monster) : ();
	}

	my $key = lc $query;
	my %ids;
	$ids{$_} = 1 for @{$self->{state}{by_aegis}{$key} || []};
	$ids{$_} = 1 for @{$self->{state}{by_name}{$key} || []};
	return map { $self->monster($_) } sort { $a <=> $b } keys %ids;
}

1;
