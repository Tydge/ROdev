package Economy::Inventory;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use Economy::Classifier;

sub new {
    my ($class, %a) = @_;
    return bless { %a, classifier => Economy::Classifier->new(%a) }, $class;
}
# Canonical wire-visible identity; inventory slot is deliberately separate.
sub signature {
    my ($item) = @_;
    my $cards = $item->{cards} // '';
    my @cards = length($cards) == 8 ? unpack('v4', $cards) : unpack('V4', $cards . "\0" x (16-length($cards))) ;
    my $options = $item->{options} // '';
    $options = unpack('H*', $options) unless ref $options;
    return sha256_hex(JSON::PP->new->canonical->encode([
        0+($item->{nameID}||0), 0+($item->{identified}||0), 0+($item->{broken}||0),
        0+($item->{upgrade}||0), 0+($item->{grade}||0), \@cards, $options || ('00' x 25)
    ]));
}
sub price {
    my ($self, $id) = @_;
    my $p = $self->{prices}{$id};
    return defined($p) && $p =~ /^\d+$/ && $p > 0 && $p <= 1_000_000_000 ? 0+$p : undef;
}
sub eligible {
    my ($self, $item, $gear_ready) = @_;
    return defined($self->price($item->{nameID})) &&
        $self->{classifier}->classify_item($item, gear_ready => $gear_ready)->{decision} eq 'MERCHANT_SELL';
}
sub candidates {
    my ($self, $items, $gear_ready) = @_;
    my @out;
    for my $i (sort { $a->{nameID} <=> $b->{nameID} || $a->{binID} <=> $b->{binID} } @$items) {
        next unless $self->eligible($i, $gear_ready) && ($i->{amount}||0) > 0;
        push @out, { nameID => 0+$i->{nameID}, amount => 0+$i->{amount},
            slot => 0+$i->{binID}, sig => signature($i) };
    }
    return \@out;
}
sub totals {
    my ($items) = @_;
    my %n;
    $n{$_->{sig} // signature($_)} += $_->{amount} for @$items;
    return \%n;
}
sub snapshot {
    my ($items, $zeny, $cart) = @_;
    return { inventory => totals($items), zeny => 0+$zeny, cart => totals($cart||[]) };
}
sub matches {
    my ($before, $after, $batch, $total, $role, $success) = @_;
    return 0 unless $before && $after;
    my %expected = %{$before->{inventory}};
    my $sign = $role eq 'buyer' ? 1 : -1;
    $expected{$_->{sig}} += $sign * $_->{amount} for $success ? @$batch : ();
    delete $expected{$_} for grep { !$expected{$_} } keys %expected;
    my %actual = %{$after->{inventory}};
    delete $actual{$_} for grep { !$actual{$_} } keys %actual;
    my $json = JSON::PP->new->canonical;
    return $after->{zeny} == $before->{zeny} - ($success ? $sign*$total : 0)
        && $json->encode(\%expected) eq $json->encode(\%actual)
        && $json->encode($before->{cart}) eq $json->encode($after->{cart});
}
# Conservative slot accounting: reserve a slot per incoming entry even if it
# could merge. This can defer a safe trade but cannot overbook storage.
sub capacity {
    my ($self, $items, $total, $ctx) = @_;
    return 'ASSETS_NOT_READY' unless $ctx->{ready};
    return 'INSUFFICIENT_ZENY' if $ctx->{zeny} < $total;
    my $weight = 0;
    my %amount;
    for my $i (@$items) {
        my $m = $self->{catalog}{$i->{nameID}};
        return 'UNKNOWN_ITEM' unless $m && exists $m->{Weight};
        return 'NOT_CARTABLE' if ($m->{Trade}||{})->{NoCart};
        return 'INVALID_AMOUNT' unless $i->{amount} =~ /^\d+$/ && $i->{amount} > 0 && $i->{amount} <= 30000;
        my $equipment = $m->{Type} eq 'Weapon' || $m->{Type} eq 'Armor';
        return 'INVALID_AMOUNT' if $equipment && $i->{amount} != 1;
        $weight += $m->{Weight} * $i->{amount} / 10;
        $amount{$i->{nameID}} += $i->{amount} unless $equipment;
    }
    for my $id (keys %amount) {
        my $s = $self->{catalog}{$id}{Stack} || {};
        for my $where (qw(Inventory Cart)) {
            my $limit = $s->{Amount} && ($s->{$where} // ($where eq 'Inventory')) ? $s->{Amount} : 30000;
            my $existing = $ctx->{lc($where).'_amounts'}{$id} || 0;
            return uc($where).'_STACK_LIMIT' if $existing + $amount{$id} > $limit;
        }
    }
    return 'INVENTORY_FULL' if $ctx->{inventory_free} < @$items;
    return 'OVERWEIGHT' if $ctx->{weight} + $weight > $ctx->{weight_max};
    return 'CART_FULL' if $ctx->{cart_free} < @$items;
    return 'CART_OVERWEIGHT' if $ctx->{cart_weight} + $weight > $ctx->{cart_weight_max};
    return '';
}
1;
