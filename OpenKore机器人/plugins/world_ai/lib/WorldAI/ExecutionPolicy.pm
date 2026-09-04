package WorldAI::ExecutionPolicy;

use strict;
use warnings;

sub new {
	my ($class, %args) = @_;
	return bless {
		allow_npc => $args{allow_npc} ? 1 : 0,
		max_hops  => defined($args{max_hops}) ? 0 + $args{max_hops} : undef,
	}, $class;
}

# 校验 world_ai_exec_max_hops：非法值（0、负数、字符串、>10）返回 undef，由调用方回退默认。
sub normalize_max_hops {
	my ($class, $value) = @_;
	return undef unless defined $value;
	$value =~ s/^\s+|\s+$//g if defined $value;
	return undef if $value eq '' || $value !~ /^\d+$/;
	my $n = 0 + $value;
	return undef if $n < 1 || $n > 10;
	return $n;
}

sub route_options {
	return {
		budget       => 0,
		noGoCommand  => 1,
		noTeleSpawn  => 1,
		noWarpItem   => 1,
		noAirship    => 1,
	};
}

sub evaluate {
	my ($self, $route) = @_;
	my @reasons;

	push @reasons, 'route_not_reachable'
		unless $route && ($route->{status} || '') eq 'REACHABLE';
	if ($route && ($route->{status} || '') eq 'REACHABLE') {
		push @reasons, 'route_zeny_nonzero' if ($route->{route_zeny} || 0) != 0;
		push @reasons, 'route_tickets_nonzero' if ($route->{route_tickets} || 0) != 0;
		push @reasons, 'npc_route_disabled' if !$self->{allow_npc} && $route->{uses_npc};
		push @reasons, 'command_route_disabled' if $route->{uses_command};
		push @reasons, 'airship_route_disabled' if $route->{uses_airship};
		push @reasons, 'save_teleport_disabled' if $route->{uses_save_teleport};
		push @reasons, 'warp_item_disabled' if $route->{uses_warp_item};
		push @reasons, 'route_hops_exceeded'
			if defined($self->{max_hops}) && ($route->{route_hops} || 0) > $self->{max_hops};
	}

	return {
		allowed => @reasons ? 0 : 1,
		reasons => \@reasons,
		code    => @reasons ? uc($reasons[0]) : 'ALLOWED',
	};
}

1;
