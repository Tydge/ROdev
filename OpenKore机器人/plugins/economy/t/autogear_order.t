use strict;
use warnings;
use Test::More;
use FindBin;
use Globals qw(%config $char $net);
use Plugins;
use AI;
use Network;
{
    package LocalTestNet;
    sub getState { Network::IN_GAME }
}
my $plugin = "$FindBin::Bin/../../autoGear/autoGear.pl";
do $plugin or die($@ || $!);
$config{autoGear} = 1;
$char = {};
$net = bless {}, 'LocalTestNet';
my ($evaluations, $events, $upgrading) = (0,0,0);
my $action = '';
my $hooks = Plugins::addHooks(['autoGear_evaluation_complete', sub { $events++ }]);
{
    no warnings qw(redefine once);
    local *AI::action = sub { $action };
    local *autoGear::choose_one_upgrade = sub { $evaluations++; return $upgrading };
    for my $busy (qw(attack skill_use npc sellAuto buyAuto storageAuto deal equip)) {
        $action=$busy;
        autoGear::request_check();
        autoGear::on_ai_pre();
    }
    is($evaluations,0,'no gear evaluation while busy');
    is($events,0,'no classification event while busy');
    $action=''; $upgrading=1;
    autoGear::request_check(); autoGear::on_ai_pre();
    is($evaluations,1,'safe tick evaluates gear');
    is($events,0,'equip request does not authorize classification before acknowledgement');
    $upgrading=0;
    autoGear::request_check(); autoGear::on_ai_pre();
    is($events,1,'classification event follows completed evaluation with no pending upgrade');
    $config{autoGear}=0;
    autoGear::request_check(); autoGear::on_ai_pre();
    is($events,1,'disabled autoGear does not authorize classification');
}
Plugins::delHooks($hooks);
autoGear::on_unload();
done_testing;
