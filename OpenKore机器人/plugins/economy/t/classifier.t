use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Economy::Classifier;
use JSON::PP qw(decode_json encode_json);
my $catalog = {
    909 => {Type=>'Etc'},
    4001 => {Type=>'Card'},
    1205 => {Type=>'Weapon', Locations=>{Right_Hand=>1}},
    2302 => {Type=>'Armor', Locations=>{Armor=>1}},
    2601 => {Type=>'Armor', Locations=>{Right_Accessory=>1}},
    501 => {Type=>'Healing'}, 619 => {Type=>'Usable'},
    713 => {Type=>'Etc'}, 7773 => {Type=>'Etc'},
    6001 => {Type=>'Etc', Trade=>{NoTrade=>1}},
    9998 => {Type=>'Weapon', Locations=>{Right_Hand=>1},CustomOverride=>1},
};
my $c = Economy::Classifier->new(catalog=>$catalog, npc_rules=>{909=>{sell=>1},all=>{sell=>1},'Rocker Card'=>{sell=>1}});
sub check {
    my ($label, $item, $decision, $reason, %context) = @_;
    my $before = encode_json($item);
    is_deeply($c->classify_item($item, gear_ready=>1, %context),
        {decision=>$decision,reason=>$reason}, $label);
    is(encode_json($item), $before, "$label does not mutate inventory");
}
check('numeric allowlist',{nameID=>909,name=>'different language'},'NPC_SELL','NPC_ALLOWLIST');
check('card',{nameID=>4001},'MERCHANT_SELL','CARD');
check('weapon',{nameID=>1205,identified=>1},'MERCHANT_SELL','EQUIPMENT');
check('slotted refined carded weapon',{nameID=>1205,identified=>1,upgrade=>7,cards=>pack('v4',4001,0,0,0)},'MERCHANT_SELL','EQUIPMENT');
check('armor',{nameID=>2302,identified=>1},'MERCHANT_SELL','EQUIPMENT');
check('accessory uses Armor/location',{nameID=>2601,identified=>1},'MERCHANT_SELL','EQUIPMENT');
check('unidentified',{nameID=>1205,identified=>0},'KEEP','UNIDENTIFIED');
check('equipped',{nameID=>1205,identified=>1,equipped=>2},'KEEP','EQUIPPED');
check('upgrade reserved',{nameID=>1205,identified=>1},'KEEP','AUTOGEAR_RESERVED',reserved=>1);
check('evaluation pending',{nameID=>1205,identified=>1},'KEEP','AUTOGEAR_PENDING',gear_ready=>0);
check('starter',{nameID=>1243},'KEEP','STARTER_GEAR');
check('unknown',{nameID=>99999999},'KEEP','UNKNOWN');
check('known custom',{nameID=>9998,identified=>1},'KEEP','CUSTOM_OVERRIDE');
check('potion',{nameID=>501},'KEEP','DEFAULT_KEEP');
check('taming item',{nameID=>619},'KEEP','DEFAULT_KEEP');
check('crafting material',{nameID=>713},'KEEP','DEFAULT_KEEP');
check('currency',{nameID=>7773},'KEEP','DEFAULT_KEEP');
check('quest restriction',{nameID=>6001},'KEEP','NOT_TRADABLE');
for my $flag (qw(locked favorite bound bindOnEquipType)) {
    check($flag,{nameID=>4001,$flag=>1},'KEEP','LOCKED_OR_BOUND');
}
check('rental',{nameID=>1205,expire=>1},'KEEP','RENTAL');
check('server instance restriction',{nameID=>4001,tradable=>0},'KEEP','NOT_TRADABLE');
check('broken',{nameID=>1205,identified=>1,broken=>1},'KEEP','BROKEN');
$catalog->{1205}{Trade}={NoTrade=>1};
check('server metadata no trade',{nameID=>1205,identified=>1},'KEEP','NOT_TRADABLE');
delete $catalog->{1205}{Trade};
$catalog->{909}{Trade}={NoSell=>1};
check('server metadata no sell',{nameID=>909},'KEEP','DEFAULT_KEEP');
check('invalid item',{},'KEEP','INVALID_ITEM');
check('invalid id',{nameID=>'abc'},'KEEP','INVALID_ID');
my $missing = Economy::Classifier->new();
is($missing->classify_item({nameID=>4001})->{decision},'KEEP','missing catalog fails closed');
# Integration: real generated server catalog plus actual OpenKore parser.
if (@ARGV) {
    require FileParsers;
    open my $fh, '<', "$FindBin::Bin/../item_catalog.json" or die $!;
    my $real = decode_json(do {local $/; <$fh>});
    my %rules;
    FileParsers::parseItemsControl($ARGV[0], \%rules);
    my $actual = Economy::Classifier->new(catalog=>$real,npc_rules=>\%rules);
    my @bad;
    for my $id (keys %$real) {
        my $result=$actual->classify_item({nameID=>$id,identified=>1},gear_ready=>1);
        push @bad,$id if $result->{decision} eq 'NPC_SELL' && !($rules{$id}||{})->{sell};
        push @bad,$id if $real->{$id}{Type} =~ /^(Card|Weapon|Armor)$/ && $result->{decision} eq 'NPC_SELL';
    }
    is_deeply(\@bad,[],'entire live server catalog: classification never expands NPC sale policy');
    is($actual->classify_item({nameID=>4001})->{decision},'MERCHANT_SELL','real card metadata');
    is($actual->classify_item({nameID=>2601,identified=>1},gear_ready=>1)->{decision},'MERCHANT_SELL','real accessory metadata');
}
done_testing;
