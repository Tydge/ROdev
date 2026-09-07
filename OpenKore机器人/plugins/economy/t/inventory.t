use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP qw(decode_json);
use Economy::Inventory;
sub read_json {open my $f,'<',$_[0] or die $!; decode_json(do {local $/; <$f>})}
my $catalog=read_json("$FindBin::Bin/../item_catalog.json");
my $p=Economy::Inventory->new(catalog=>$catalog,prices=>read_json("$FindBin::Bin/../trade_prices.json"));
sub item {my ($slot,$id,$amount,%rest)=@_; return {binID=>$slot,nameID=>$id,amount=>$amount,identified=>1,%rest}}
sub cap {return {ready=>1,zeny=>100000,inventory_free=>100,weight=>0,weight_max=>20000,cart_free=>100,cart_weight=>0,cart_weight_max=>8000,inventory_amounts=>{},cart_amounts=>{},@_}}
my $base=item(0,1208,1);
my @different=(item(1,1208,1,upgrade=>1),item(2,1208,1,cards=>pack('V4',4021,0,0,0)),item(3,1208,1,options=>pack('vVC',1,10,0).("\0"x18)));
my $sig=Economy::Inventory::signature($base);
is(Economy::Inventory::signature({%$base,binID=>9}),$sig,'slot is separate from item identity');
is(Economy::Inventory::signature({%$base,cards=>pack('v4',4021,0,0,0)}),Economy::Inventory::signature($different[1]),'8 and 16 byte card arrays canonicalize equally');
isnt(Economy::Inventory::signature($_),$sig,'instance attributes retained') for @different;
my @protected=(item(5,1208,1,equipped=>1),item(6,1208,1,locked=>1),item(7,1208,1,identified=>0),item(8,4021,1,bound=>1),item(9,999999,1));
is(scalar @{$p->candidates(\@protected,1)},0,'protected and unknown items never offered');
is(scalar @{$p->candidates([$base],0)},0,'gear evaluation required before offering equipment');
my $c=$p->candidates([@different,$base,item(4,4021,7)],1);
is(scalar @$c,5,'same nameID separate instances and stack retained');
is_deeply([map {$_->{slot}} @$c],[0,1,2,3,4],'stable nameID then slot ordering');
is($p->capacity($c,82000,cap()),'','valid mixed inventory fits');
for my $case (
 ['ASSETS_NOT_READY',ready=>0],['INSUFFICIENT_ZENY',zeny=>81999],
 ['INVENTORY_FULL',inventory_free=>4],['OVERWEIGHT',weight_max=>1],
 ['CART_FULL',cart_free=>4],['CART_OVERWEIGHT',cart_weight_max=>1],
 ['INVENTORY_STACK_LIMIT',inventory_amounts=>{4021=>29999}],['CART_STACK_LIMIT',cart_amounts=>{4021=>29999}]) {
    my ($reason,@args)=@$case;
    is($p->capacity($c,82000,cap(@args)),$reason,$reason.' refused before payment');
}
is($p->capacity([{nameID=>1208,amount=>2}],1,cap()),'INVALID_AMOUNT','equipment cannot be stacked');
is($p->capacity([{nameID=>4021,amount=>30001}],1,cap()),'INVALID_AMOUNT','global stack bound enforced');
my $custom={%$catalog,4021=>{%{$catalog->{4021}},Stack=>{Amount=>5,Inventory=>1,Cart=>1}}};
my $limited=Economy::Inventory->new(catalog=>$custom,prices=>{4021=>10000});
is($limited->capacity([{nameID=>4021,amount=>6}],60000,cap()),'INVENTORY_STACK_LIMIT','per-item stack limit enforced');
my $nocart=Economy::Inventory->new(catalog=>{4021=>{%{$catalog->{4021}},Trade=>{NoCart=>1}}},prices=>{4021=>10000});
is($nocart->capacity([{nameID=>4021,amount=>1}],10000,cap()),'NOT_CARTABLE','uncartable item refused');
my $before=Economy::Inventory::snapshot([$base],1000,[]);
my $batch=$p->candidates([$base],1);
ok(Economy::Inventory::matches($before,Economy::Inventory::snapshot([],4000,[]),$batch,3000,'seller',1),'exact asset difference accepted');
ok(!Economy::Inventory::matches($before,Economy::Inventory::snapshot([],3999,[]),$batch,3000,'seller',1),'wrong zeny difference rejected');
ok(!Economy::Inventory::matches($before,Economy::Inventory::snapshot([],4000,[$base]),$batch,3000,'seller',1),'cart mutation during trade rejected');
ok(Economy::Inventory::matches($before,$before,$batch,3000,'seller',0),'rollback requires unchanged inventory and wallet');
done_testing;
