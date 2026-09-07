package Economy::Classifier;
use strict;
use warnings;

# Pure read-only policy. The caller supplies parsed items_control as the sole
# NPC allowlist and authoritative server metadata. No OpenKore dependency.
sub new {
    my ($class, %args) = @_;
    return bless {
        catalog => $args{catalog} || {},
        npc_rules => $args{npc_rules} || {},
        # Starting equipment is retained even when duplicated.
        keep_ids => $args{keep_ids} || { map { $_ => 1 } qw(1101 1201 1243 1501 1601 1701 2101 2301) },
    }, $class;
}

sub classify_item {
    my ($self, $item, %context) = @_;
    my $result = sub { return { decision => $_[0], reason => $_[1] }; };
    return $result->('KEEP', 'INVALID_ITEM') unless $item && defined $item->{nameID};
    my $id = $item->{nameID};
    return $result->('KEEP', 'INVALID_ID') unless $id =~ /^\d+$/ && $id > 0;
    return $result->('KEEP', 'EQUIPPED') if $item->{equipped};
    return $result->('KEEP', 'LOCKED_OR_BOUND') if
        $item->{locked} || $item->{favorite} || $item->{bound} || $item->{bindOnEquipType};
    return $result->('KEEP', 'RENTAL') if $item->{expire} || $item->{expireDate};
    return $result->('KEEP', 'AUTOGEAR_RESERVED') if $context{reserved};
    return $result->('KEEP', 'STARTER_GEAR') if $self->{keep_ids}{$id};
    my $meta = $self->{catalog}{$id};
    return $result->('KEEP', 'UNKNOWN') unless $meta && $meta->{Type};
    return $result->('KEEP', 'CUSTOM_OVERRIDE') if $meta->{CustomOverride};
    return $result->('KEEP', 'NOT_TRADABLE') if
        (exists $item->{tradable} && !$item->{tradable}) || ($meta->{Trade} || {})->{NoTrade};
    my $type = $meta->{Type};
    if ($type eq 'Weapon' || $type eq 'Armor') {
        return $result->('KEEP', 'AUTOGEAR_PENDING') unless $context{gear_ready};
        return $result->('KEEP', 'UNIDENTIFIED') unless $item->{identified};
        return $result->('KEEP', 'BROKEN') if $item->{broken};
        return $result->('KEEP', 'UNKNOWN_LOCATION') unless keys %{$meta->{Locations} || {}};
        # Accessories are Armor with accessory locations, not a synthetic type.
        return $result->('MERCHANT_SELL', 'EQUIPMENT');
    }
    return $result->('MERCHANT_SELL', 'CARD') if $type eq 'Card';
    # Only exact numeric rules count, never display-name rules or the all rule.
    my $rule = $self->{npc_rules}{$id} || {};
    return $result->('NPC_SELL', 'NPC_ALLOWLIST') if
        $type eq 'Etc' && $rule->{sell} && !($meta->{Trade} || {})->{NoSell};
    return $result->('KEEP', 'DEFAULT_KEEP');
}

1;
