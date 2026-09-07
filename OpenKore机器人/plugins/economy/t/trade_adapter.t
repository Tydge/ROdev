use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Economy::Inventory;
use Globals qw($char $field $net $messageSender %config $buyershopstarted $shopstarted %incomingDeal %outgoingDeal %currentDeal $playersList);
use Network;
{
    package TestNet; sub getState {Network::IN_GAME()}
    package TestField; sub baseName {'prontera'}
    package TestPeer; sub name {$_[0]{name}}
    package TestItems;
    sub new {bless {items=>$_[1]||[],weight=>0,weight_max=>8000},$_[0]}
    sub getItems {$_[0]{items}}
    sub isReady {1}
    sub size {scalar @{$_[0]{items}}}
    sub items_max {100}
    sub get {my ($s,$slot)=@_; my ($i)=grep {$_->{binID}==$slot} @{$s->{items}}; $i}
    package TestChar;
    sub inventory {$_[0]{inventory}}
    sub cart {$_[0]{cart}}
    package TestSender;
    our @sent;
    sub sendDealReply {shift;push @sent,['reply',@_]}
    sub sendCurrentDealCancel {push @sent,['cancel']}
    sub sendDealAddItem {shift;push @sent,['add',@_]}
    sub sendDealFinalize {push @sent,['lock']}
    sub sendDealTrade {push @sent,['commit']}
    sub sendPrivateMsg {shift;push @sent,['pm',@_]}
}
$net=bless {},'TestNet'; $field=bless {},'TestField'; $messageSender=bless {},'TestSender';
$char=bless {zeny=>100000,weight=>0,weight_max=>10000,pos_to=>{x=>156,y=>170},inventory=>TestItems->new,cart=>TestItems->new},'TestChar';
$playersList=[bless({name=>'Penny',pos_to=>{x=>157,y=>170}},'TestPeer')];
%config=(economy_trade_enabled=>1,economy_trade_role=>'buyer',economy_trade_sellers=>'Penny',economy_buy_store_enabled=>0);
$buyershopstarted=$shopstarted=0;
do "$FindBin::Bin/../economy.pl" or die($@||$!);
my @logs;
{no warnings qw(redefine once); *economy::econ_log=sub {push @logs,$_[0]}; *economy::econ_warn=sub {push @logs,$_[0]};}
sub count_sent {scalar grep {$_->[0] eq $_[0]} @TestSender::sent}
my $frame='SELL_ITEM '.('a' x 24).' 0 4021 30000 '.('b' x 64);
my $pm_before=count_sent('pm');
economy::_send_trade_pm({to=>'Penny',msg=>$frame});
is(count_sent('pm'),$pm_before+1,'long manifest remains one PM despite native 80-char message default');
is_deeply($TestSender::sent[-1],['pm','Penny',$frame],'manifest fingerprint preserved byte for byte');
my $card={nameID=>4021,amount=>2,identified=>1,binID=>0,ID=>pack('v',2)};
my $sig=Economy::Inventory::signature($card);
economy::on_trade_pm(undef,{privMsgUser=>'Penny',privMsg=>'SELL_REQUEST abcdef12 1'});
economy::on_trade_pm(undef,{privMsgUser=>'Penny',privMsg=>"SELL_ITEM abcdef12 0 4021 2 $sig"});
%incomingDeal=(name=>'Penny');
economy::on_trade_incoming(undef,{name=>'Penny'});
is_deeply($TestSender::sent[-1],['reply',3],'adapter accepts authenticated request');
%incomingDeal=(); %currentDeal=(name=>'Penny');
economy::on_trade_engaged(undef,{name=>'Penny'});
economy::on_trade_other_item(undef,$card);
economy::on_trade_tick(1);
is(count_sent('add'),1,'one Zeny offer packet');
is(count_sent('lock'),0,'no wait for nonexistent payer acknowledgement, waits for seller lock');
is($currentDeal{you_zeny},20000,'offer is native deal field');
is($char->{zeny},100000,'plugin does not debit assets when quoting');
$currentDeal{other_finalize}=1;
economy::on_trade_finalized();
is(count_sent('lock'),1,'seller lock triggers buyer lock');
is(count_sent('add'),1,'lock never sends Zeny twice');
$currentDeal{you_finalize}=1; $char->{zeny}=80000; # native speculative debit
# This native index-zero acknowledgement belongs to lock, not Zeny addition.
economy::on_trade_own_ack(undef,{ID=>pack('v',0),fail=>0});
economy::on_trade_tick(1);
is(count_sent('commit'),1,'both server locks trigger commit');
$char->inventory->{items}=[$card];
economy::on_trade_zeny(undef,{zeny=>80000}); # actual server wallet event
%currentDeal=();
economy::on_trade_complete();
ok(grep(/VERIFIED total=20000 zeny_before=100000 zeny_after=80000/,@logs),'completion verified against server wallet and inventory');
# Packet cancellation mapping must distinguish active sessions from requests.
%currentDeal=(name=>'Penny');
economy::_execute_trade_actions([{type=>'cancel_deal'}]);
is_deeply($TestSender::sent[-1],['cancel'],'active Trade uses sendCurrentDealCancel');
%currentDeal=(); %outgoingDeal=(ID=>'peer');
economy::_execute_trade_actions([{type=>'cancel_deal'}]);
is_deeply($TestSender::sent[-1],['reply',4],'pending request uses refusal reply');
is($char->{zeny},80000,'cancellation never restores wallet in plugin memory');
is(scalar @{$char->inventory->getItems},1,'cancellation never edits inventory');
%outgoingDeal=();
# Previously received stock reserves future Cart capacity across batches.
my $ctx=economy::_trade_context('Penny');
is($ctx->{capacity}{cart_free},99,'pending acquired inventory reserves Cart slot');
is($ctx->{capacity}{cart_amounts}{4021},2,'pending stock reserves Cart stack amount');
$config{world_ai_auto_execute}=1;
ok(!economy::_trade_context('Penny')->{safe},'roaming world_ai bot cannot start until Stage 7 integration');
$config{world_ai_auto_execute}=0; $config{economy_trade_enabled}=0;
ok(!economy::_trade_context('Penny')->{safe},'disabled economy cannot start or accept new sessions');
%currentDeal=(); %incomingDeal=(); %outgoingDeal=();
economy::on_unload();
done_testing;
