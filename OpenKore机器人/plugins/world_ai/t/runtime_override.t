use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";

use WorldAI::RuntimeOverride;

my %config = (
	lockMap => 'prt_fild08', lockMap_x => 170, lockMap_y => 350,
	lockMap_randX => 150, lockMap_randY => 150, unrelated => 'keep',
	route_maxWarpFee => '', route_warpByItem => 1, saveMap_warp => 1,
);
my %mon_control = (
	all => { attack_auto => 0, teleport_auto => 1 },
	poring => { attack_auto => 1, items_take => 1 },
);
my %original_config = %config;
my %original_poring = %{$mon_control{poring}};

my $override = WorldAI::RuntimeOverride->new(config => \%config, mon_control => \%mon_control);
ok(!$override->active, 'override starts inactive');
ok($override->apply(target_map => 'prt_fild07', monster => 'Rocker'), 'override applies');
ok($override->active, 'override becomes active');
is($config{lockMap}, 'prt_fild07', 'lockMap changes in supplied runtime hash');
is($config{lockMap_x}, '', 'old lockMap x is cleared');
is($config{lockMap_y}, '', 'old lockMap y is cleared');
is($config{lockMap_randX}, '', 'old random x is cleared');
is($config{lockMap_randY}, '', 'old random y is cleared');
is($config{route_maxWarpFee}, 0, 'actual MapRoute warp fee is constrained');
is($config{route_warpByItem}, 0, 'actual MapRoute item warp is disabled');
is($config{saveMap_warp}, 0, 'actual MapRoute save warp is disabled');
is($config{unrelated}, 'keep', 'unrelated config is untouched');
is($mon_control{rocker}{attack_auto}, 1, 'target monster is enabled');
is($mon_control{rocker}{teleport_auto}, 1, 'all fallback behavior is preserved');
is_deeply($mon_control{poring}, \%original_poring, 'existing other monster control is untouched');

my $double_apply = eval { $override->apply(target_map => 'pay_fild08', monster => 'Spore'); 1 };
ok(!$double_apply, 'second apply is rejected transactionally');

ok($override->restore, 'override restores');
ok(!$override->active, 'override becomes inactive');
for my $key (qw(lockMap lockMap_x lockMap_y lockMap_randX lockMap_randY route_maxWarpFee route_warpByItem saveMap_warp unrelated)) {
	is($config{$key}, $original_config{$key}, "$key is restored exactly");
}
ok(!exists $mon_control{rocker}, 'new target entry is removed on restore');

$mon_control{rocker} = { attack_auto => 0, items_take => 2 };
my %saved_rocker = %{$mon_control{rocker}};
$override->apply(target_map => 'prt_fild07', monster => 'Rocker');
is($mon_control{rocker}{attack_auto}, 1, 'existing target is temporarily enabled');
$override->restore;
is_deeply($mon_control{rocker}, \%saved_rocker, 'existing target entry is restored exactly');

done_testing;
