use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
# PERL5LIB must point at the installed OpenKore src and src/deps (absolute paths).
use FileParsers;
use Misc;
use Globals qw(%items_control);
my ($policy, $catalog) = @ARGV;
die "usage: npc_allowlist.t ITEMS_CONTROL CATALOG_JSON\n" unless $catalog;
FileParsers::parseItemsControl($policy, \%items_control);
my @approved = (705, 909, 920, 938, 949);
is_deeply([sort keys %items_control], [sort ('all', @approved)], 'only default KEEP and approved numeric IDs; no name overrides');
for my $id ('all', @approved) {
    is_deeply($items_control{$id}, {keep=>0, storage=>0, sell=>($id eq 'all' ? 0 : 1), cart_add=>0, cart_get=>0}, "exact rule $id");
}
open my $fh, '<', $catalog or die $!;
my $items = decode_json(do { local $/; <$fh> });
my %by_id = map { $_->{Id} => $_ } @$items;
for my $id (@approved) {
    is($by_id{$id}{Type}, 'Etc', "approved $id is actual server Etc");
}
my %approved = map { $_ => 1 } @approved;
my @unexpected;
my %protected;
for my $item (@$items) {
    my $id = $item->{Id};
    $protected{$item->{Type} || 'Unknown'}++ unless $approved{$id};
    for my $name ($item->{Name}, $item->{AegisName}, 'localized item name') {
        my $rule = Misc::items_control($name || '', $id);
        push @unexpected, "$id/$name" if !!$rule->{sell} != !!$approved{$id};
    }
}
is_deeply(\@unexpected, [], 'full server catalog: only allowlisted IDs sell, regardless of display name');
ok(($protected{Card} || 0) > 0 && ($protected{Weapon} || 0) > 0 && ($protected{Armor} || 0) > 0, 'catalog covers cards, weapons and armor including accessories');
for my $id (512, 515, 501, 569, 713, 1750, 6377, 99999999) {
    ok(!Misc::items_control('unknown/localized', $id)->{sell}, "food/supplies/license/unknown $id kept");
}
# Native sellAuto consults this same rule after checking equipped/sellable;
# equipment attributes and quantity cannot enable selling when sell == 0.
for my $id (1201, 1205, 2301, 2601, 4001) {
    ok(!Misc::items_control($by_id{$id}{Name} || '', $id)->{sell}, "weapon/slotted weapon/armor/accessory/card $id kept even as duplicates");
}
diag('checked '.scalar(@$items).' server items; protected types: '.join(', ', map { "$_=$protected{$_}" } sort keys %protected));
done_testing;
