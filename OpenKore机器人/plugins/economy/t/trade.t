use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP qw(decode_json);
use Economy::Inventory;
use Economy::Trade;
my $now=1000;
my $seq=0;
sub read_json {open my $f,'<',$_[0] or die $!; return decode_json(do {local $/; <$f>})}
my $policy=Economy::Inventory->new(catalog=>read_json("$FindBin::Bin/../item_catalog.json"),prices=>read_json("$FindBin::Bin/../trade_prices.json"));
sub bot {
    my ($role)=@_;
    return Economy::Trade->new(role=>$role,policy=>$policy,merchant=>'Cartwright',sellers=>{Penny=>1},
        now_fn=>sub {$now},nonce_fn=>sub {sprintf('%016x',++$seq)},timeout=>30,cooldown=>15);
}
sub item {my ($slot,$id,$amount,%extra)=@_; return {binID=>$slot,nameID=>$id,amount=>$amount,identified=>1,%extra}}
sub cap {return {ready=>1,zeny=>1_000_000,inventory_free=>100,weight=>0,weight_max=>20000,cart_free=>100,cart_weight=>0,cart_weight_max=>8000,inventory_amounts=>{},cart_amounts=>{},@_}}
sub ctx {return {safe=>1,trade_safe=>1,peer_near=>1,capacity=>cap(),@_}}
sub actions {my ($a,$type)=@_; return [grep {$_->{type} eq $type} @$a]}
sub handshake {
    my ($s,$b,$items)=@_;
    my $a=$s->tick(%{ctx(candidates=>$policy->candidates($items,1))});
    for my $m (@{actions($a,'send_pm')}) {
        my $reply=$b->on_pm('Penny',$m->{msg},ctx());
        $s->on_pm('Cartwright',$_->{msg},ctx()) for @{actions($reply,'send_pm')};
    }
    return $a;
}
sub engage {
    my ($s,$b,$items,$stock,$sz,$bz)=@_;
    $stock||=[]; $sz//=1000; $bz//=1_000_000;
    $b->on_incoming_deal('Penny',ctx());
    $b->on_engaged('Penny',ctx(snapshot=>Economy::Inventory::snapshot($stock,$bz,[]),zeny_version=>1));
    return $s->on_engaged('Cartwright',ctx(snapshot=>Economy::Inventory::snapshot($items,$sz,[]),zeny_version=>1));
}
sub offers {
    my ($s,$b,$items,$first)=@_;
    my $a=$first;
    my @sent;
    while (my $add=actions($a,'add_item')->[0]) {
        push @sent,$add;
        my ($i)=grep {$_->{binID}==$add->{slot}} @$items;
        $b->on_other_item({%$i,amount=>$add->{amount}});
        $a=$s->on_own_item(@$add{qw(slot sig amount)});
    }
    return \@sent;
}
sub settle {
    my ($s,$b,$sent,$all,$stock,$sz,$bz)=@_;
    $stock||=[]; $sz//=1000; $bz//=1_000_000;
    my $total=0; $total+=$policy->price($_->{nameID})*$_->{amount} for @$sent;
    my $bc=ctx(peer_name=>'Penny');
    my $sc=ctx(peer_name=>'Cartwright',other_zeny=>$total);
    my $pay=$b->tick(%$bc);
    is(actions($pay,'add_zeny')->[0]{amount},$total,'buyer pays exact aggregate total');
    is(scalar @{actions($pay,'finalize')},0,'waits for seller to verify server quote');
    $b->on_own_zeny;
    is(scalar @{actions($b->tick(%$bc,other_finalized=>1),'finalize')},1,'buyer locks after seller locks');
    is(scalar @{actions($s->tick(%$sc),'finalize')},1,'seller locks after all item acknowledgements and exact quote');
    is(scalar @{actions($s->tick(%$sc,other_finalized=>1),'commit')},0,'other lock alone cannot commit before own server lock');
    for my $pair ([$s,$sc],[$b,$bc]) {
        is(scalar @{actions($pair->[0]->tick(%{$pair->[1]},own_finalized=>1,other_finalized=>1),'commit')},1,'both acknowledged locks commit once');
        is(scalar @{actions($pair->[0]->tick(%{$pair->[1]},own_finalized=>1,other_finalized=>1),'commit')},0,'duplicate lock does not commit twice');
        $pair->[0]->on_complete;
        is($pair->[0]->state,'verifying','server event alone is not verified success');
    }
    my %slots=map {$_->{slot}=>1} @$sent;
    my @left=grep {!$slots{$_->{binID}}} @$all;
    my @received=map {my $x=$_; my ($i)=grep {$_->{binID}==$x->{slot}} @$all; +{%$i}} @$sent;
    my $sa=Economy::Inventory::snapshot(\@left,$sz+$total,[]);
    my $ba=Economy::Inventory::snapshot([@$stock,@received],$bz-$total,[]);
    $s->tick(%$sc,snapshot=>$sa,zeny_version=>1,server_zeny=>$sa->{zeny});
    is($s->state,'verifying','stale zeny version cannot validate assets');
    my $bv=$b->tick(%$bc,snapshot=>$ba,zeny_version=>2,server_zeny=>$ba->{zeny});
    $s->on_pm('Cartwright',$_->{msg},ctx()) for @{actions($bv,'send_pm')};
    $s->tick(%$sc,snapshot=>$sa,zeny_version=>2,server_zeny=>$sa->{zeny});
    is($s->state,'done','seller asset verification completes');
    is($b->state,'done','buyer asset verification completes');
    is_deeply($s->abort('DISABLED'),[],'disabling verified transaction does not cancel or expect rollback');
    is($s->state,'done','verified settlement remains done after disable');
    push @$stock,@received;
    return \@left;
}

for my $n (1,10,11,20,21) {
    subtest "$n inventory entries batched sequentially" => sub {
        my $s=bot('seller'); my $b=bot('buyer');
        my @stock; my ($sz,$bz)=(1000,1_000_000);
        my @items=map {item($_,1208,1,upgrade=>$_%10,cards=>pack('V4',4021+$_,0,0,0))} 0..$n-1;
        my $items=\@items; my @sizes; my %seen;
        while (@$items) {
            $b->tick;
            handshake($s,$b,$items);
            is($s->state,'initiating','valid manifest handshake');
            my $a=engage($s,$b,$items,\@stock,$sz,$bz);
            is(scalar @{actions($a,'add_item')},1,'only one pending native item add');
            my $sent=offers($s,$b,$items,$a);
            push @sizes,scalar @$sent;
            ok(!grep($seen{$_->{slot}}++,@$sent),'each real inventory instance offered once');
            $items=settle($s,$b,$sent,$items,\@stock,$sz,$bz);
            my $paid=0; $paid+=$policy->price($_->{nameID})*$_->{amount} for @$sent;
            $sz+=$paid; $bz-=$paid;
            $now+=16;
        }
        my @expected=((10) x int($n/10)); push @expected,$n%10 if $n%10;
        is_deeply(\@sizes,\@expected,'correct <=10 batches, including exact boundary');
    };
}
{
    my @items=(item(0,4021,3),item(1,4051,2),item(2,1208,1),item(3,2102,1));
    my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items);
    my $sent=offers($s,$b,\@items,engage($s,$b,\@items));
    is(scalar @$sent,4,'stack quantities do not count as extra trade entries');
    settle($s,$b,$sent,\@items);
}
{
    my $b=bot('buyer');
    is_deeply($b->on_pm('Stranger','SELL_REQUEST abcdef12 1',ctx()),[],'non-whitelist ignored');
    $b->on_pm('Penny','SELL_REQUEST abcdef12 1',ctx(peer_near=>0));
    is($b->state,'idle','remote seller cannot reserve merchant');
    $b->on_pm('Penny','SELL_REQUEST abcdef12 11',ctx());
    is($b->state,'idle','11-entry request rejected');
    $b->on_pm('Penny','SELL_REQUEST abcdef12 1',ctx());
    is($b->state,'collecting','whitelisted near request accepted');
    $b->on_pm('Penny','SELL_REQUEST abcdef12 1',ctx());
    is($b->state,'collecting','repeated nonce does not create new session');
    is(scalar @{actions($b->on_incoming_deal('Stranger',ctx()),'reject_request')},1,'unmatched request explicitly refused');
}
for my $case ('wrong_quote','extra_item','changed_equipment','unexpected_zeny','bad_quantity','moved') {
    subtest $case => sub {
        my @items=(item(0,1208,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
        handshake($s,$b,\@items); my $a=engage($s,$b,\@items);
        my ($target,$out);
        if ($case eq 'wrong_quote') {$target=$s;$out=$s->tick(%{ctx(peer_name=>'Cartwright',other_zeny=>2999)});}
        elsif ($case eq 'extra_item') {$target=$s;$out=$s->on_other_item(item(1,4021,1));}
        elsif ($case eq 'unexpected_zeny') {$target=$b;$out=$b->tick(%{ctx(peer_name=>'Penny',other_zeny=>1)});}
        elsif ($case eq 'moved') {$target=$s;$out=$s->tick(%{ctx(peer_name=>'Cartwright',peer_near=>0)});}
        else {$target=$b;$out=$b->on_other_item({%{$items[0]},$case eq 'bad_quantity'?(amount=>2):(upgrade=>5)});}
        is($target->state,'cancelling','bad live offer cancels');
        is(scalar @{actions($out,'cancel_deal')},1,'active cancellation emitted');
    };
}
{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); engage($s,$b,\@items);
    $now+=31; my $out=$s->tick();
    is(scalar @{actions($out,'cancel_deal')},1,'watchdog actually cancels server session');
    $now+=16; $s->tick(%{ctx(candidates=>$policy->candidates(\@items,1))});
    is($s->state,'cancelling','cooldown alone does not clear unacknowledged cancellation');
    $s->on_cancelled;
    $s->tick(%{ctx(snapshot=>Economy::Inventory::snapshot([],1000,[]),deal_active=>0)});
    is($s->state,'rollback','partial rollback cannot restart');
    $s->tick(%{ctx(snapshot=>Economy::Inventory::snapshot(\@items,1000,[]),deal_active=>0)});
    is($s->state,'done','full rollback verified');
}
{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); engage($s,$b,\@items);
    $s->on_disconnected; $now+=100;
    my $out=$s->tick(%{ctx(candidates=>$policy->candidates(\@items,1))});
    is($s->state,'halted','disconnect stops automatic replay');
    is_deeply($out,[],'no payment or new request after uncertain disconnect');
}

{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); my $a=engage($s,$b,\@items);
    offers($s,$b,\@items,$a);
    my $out=$b->tick(%{ctx(peer_name=>'Penny',capacity=>cap(zeny=>9999))});
    is(scalar @{actions($out,'add_zeny')},0,'funds rechecked after receiving actual offers');
    is($b->state,'cancelling','insufficient funds cancels before lock');
}
{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); my $a=engage($s,$b,\@items);
    offers($s,$b,\@items,$a);
    $s->tick(%{ctx(peer_name=>'Cartwright',other_zeny=>10000)});
    my $out=$s->tick(%{ctx(peer_name=>'Cartwright',other_zeny=>0,other_finalized=>1,own_finalized=>1)});
    is($s->state,'cancelling','quote removed after lock cancels');
    is(scalar @{actions($out,'commit')},0,'changed quote cannot commit');
}
{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); engage($s,$b,\@items);
    $s->on_disconnected;
    my $before=Economy::Inventory::snapshot(\@items,1000,[]);
    $s->reconcile(ctx(snapshot=>$before,zeny_version=>1,server_zeny=>1000));
    is($s->state,'halted','stale pre-disconnect assets cannot reset');
    $s->reconcile(ctx(snapshot=>$before,zeny_version=>2,server_zeny=>1000));
    is($s->state,'idle','fresh unchanged assets allow explicit reconciliation');
}
{
    my @items=(item(0,4021,1)); my ($s,$b)=(bot('seller'),bot('buyer'));
    handshake($s,$b,\@items); my $a=engage($s,$b,\@items);
    offers($s,$b,\@items,$a);
    $s->tick(%{ctx(peer_name=>'Cartwright',other_zeny=>10000)});
    $s->tick(%{ctx(peer_name=>'Cartwright',other_zeny=>10000,own_finalized=>1,other_finalized=>1)});
    $s->on_complete;
    $now+=31;
    my $out=$s->tick(%{ctx(snapshot=>Economy::Inventory::snapshot([],999,[]),zeny_version=>2,server_zeny=>999)});
    is($s->state,'halted','asset mismatch after completion never retries');
    is(scalar @{actions($out,'commit')},0,'verification failure cannot repay');
}
{
    my $b=bot('buyer'); my $nonce='decafbad';
    $b->on_pm('Penny',"SELL_REQUEST $nonce 1",ctx());
    my $i=item(0,4021,1);
    my $out=$b->on_pm('Penny',"SELL_ITEM $nonce 0 4021 1 ".Economy::Inventory::signature($i),ctx(capacity=>cap(cart_free=>0)));
    is(scalar @{actions($out,'send_pm')},0,'no READY if Cart cannot receive goods');
    is($b->state,'cancelling','capacity failure closes handshake');
    $b->on_cancelled; $b->tick(%{ctx(deal_active=>0)}); $now+=16; $b->tick;
    $b->on_pm('Penny',"SELL_REQUEST $nonce 1",ctx());
    is($b->state,'idle','nonce still rejected after cooling down');
}

done_testing;
