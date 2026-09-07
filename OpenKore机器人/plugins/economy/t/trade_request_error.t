use strict;
use warnings;
use Test::More;
use FindBin;
use Globals qw(%incomingDeal %outgoingDeal %currentDeal $char);
do "$FindBin::Bin/../economy.pl" or die($@ || $!);
$char={zeny=>9970,inventory=>['sentinel']};
for my $type (0,1,2,4,5) {
 %incomingDeal=(name=>'KoreHelper'); %outgoingDeal=(ID=>'test'); %currentDeal=();
 economy::on_trade_request_error(undef,{type=>$type});
 is_deeply([\%incomingDeal,\%outgoingDeal],[{},{}],"server rejection $type clears pending requests");
}
%currentDeal=(name=>'Penny',you_zeny=>1000);
%incomingDeal=(name=>'KoreHelper');
economy::on_trade_request_error(undef,{type=>2});
is_deeply(\%currentDeal,{name=>'Penny',you_zeny=>1000},'engaged trade preserved');
is_deeply(\%incomingDeal,{name=>'KoreHelper'},'unrelated error cannot clear engaged session state');
%currentDeal=();
economy::on_trade_request_error(undef,{type=>3});
is_deeply(\%incomingDeal,{name=>'KoreHelper'},'acceptance is not a rejection');
economy::on_trade_request_error(undef,{type=>99});
is_deeply(\%incomingDeal,{name=>'KoreHelper'},'unknown response fails closed');
is_deeply($char,{zeny=>9970,inventory=>['sentinel']},'cleanup never changes assets');
economy::on_unload();
done_testing;
