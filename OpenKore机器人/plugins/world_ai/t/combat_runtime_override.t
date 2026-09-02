use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";

use WorldAI::CombatRuntimeOverride;

my %config = (
	attackSkillSlot_0 => 'MG_FIREBOLT',
	attackSkillSlot_0_monsters => 'Poring, Fabre',
	attackSkillSlot_0_sp => '> 20%',
	attackSkillSlot_0_dist => 8,
	attackSkillSlot_1 => 'MG_FIREBOLT',
	attackSkillSlot_1_monsters => '',
	unrelated => 'keep',
);
my %original = %config;
my $policy = {
	target_monster_name => 'Spore', target_monster_id => 1014,
	skills => [{ skill_handle => 'MG_FIREBOLT', enabled => 1, slots => [0, 1] }],
};

my $override = WorldAI::CombatRuntimeOverride->new(config => \%config);
ok(!$override->active, 'combat override starts inactive');
ok($override->apply(policy => $policy), 'combat override applies');
ok($override->active, 'combat override becomes active');
is($config{attackSkillSlot_0_monsters}, 'Poring, Fabre, Spore', 'executed target is appended to a filtered slot');
is($config{attackSkillSlot_1_monsters}, '', 'unfiltered slot remains universal');
is($config{attackSkillSlot_0_sp}, '> 20%', 'SP condition is untouched');
is($config{attackSkillSlot_0_dist}, 8, 'distance condition is untouched');
is($config{unrelated}, 'keep', 'unrelated configuration is untouched');

my $states = $override->overrides;
is(scalar(@$states), 2, 'both matching slots are reported');
ok($states->[0]{changed}, 'filtered slot reports a target sync');
ok(!$states->[1]{changed}, 'universal slot reports already allowed');

my $double_apply = eval { $override->apply(policy => $policy); 1 };
ok(!$double_apply, 'a second apply is rejected transactionally');

ok($override->restore, 'combat override restores');
ok(!$override->active, 'combat override becomes inactive');
is_deeply(\%config, \%original, 'all original runtime values are restored exactly');

$config{attackSkillSlot_0_monsters} = 'Poring, Spore';
$override->apply(policy => $policy);
is($config{attackSkillSlot_0_monsters}, 'Poring, Spore', 'existing target is not duplicated');
$override->restore;

my $normal_only = {
	target_monster_name => 'Rocker', target_monster_id => 1052,
	skills => [],
};
ok($override->apply(policy => $normal_only), 'normal-attack-only policy has a lifecycle without config changes');
is_deeply($override->overrides, [], 'normal-attack-only policy has no skill overrides');
ok($override->restore, 'normal-attack-only lifecycle restores cleanly');

done_testing;
