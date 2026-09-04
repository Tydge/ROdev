use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";

use WorldAI::ClassProfile;

my $thief = WorldAI::ClassProfile::class_family(job_id => 6);
is($thief, 'THIEF_FAMILY', 'job 6 is the Thief family');
is(WorldAI::ClassProfile::damage_type($thief), 'PHYSICAL', 'Thief is physical');
is(WorldAI::ClassProfile::combat_style($thief), 'MELEE', 'Thief is melee');
is(WorldAI::ClassProfile::baseline_skill($thief), undef, 'Thief has no baseline active skill');
is(WorldAI::ClassProfile::passive_skill($thief), 'TF_DOUBLE', 'Thief has the Double Attack passive');

my $swordman = WorldAI::ClassProfile::class_family(job_id => 1);
is($swordman, 'SWORDMAN_FAMILY', 'job 1 is the Swordman family');
is(WorldAI::ClassProfile::baseline_skill($swordman), 'SM_BASH', 'Swordman baseline is Bash');
is(WorldAI::ClassProfile::damage_type($swordman), 'PHYSICAL', 'Swordman is physical');
is(WorldAI::ClassProfile::baseline_element($swordman), undef, 'Swordman has no baseline element');

my $mage = WorldAI::ClassProfile::class_family(job_id => 2);
is($mage, 'MAGE_FAMILY', 'job 2 is the Mage family');
is(WorldAI::ClassProfile::baseline_skill($mage), 'MG_FIREBOLT', 'Mage baseline is Fire Bolt');
is(WorldAI::ClassProfile::damage_type($mage), 'MAGIC', 'Mage is magic');
is(WorldAI::ClassProfile::combat_style($mage), 'RANGED_CAST', 'Mage is a ranged caster');
is(WorldAI::ClassProfile::baseline_element($mage), 'Fire', 'Mage baseline element is Fire');

my $archer = WorldAI::ClassProfile::class_family(job_id => 3);
is($archer, 'ARCHER_FAMILY', 'job 3 is the Archer family');
is(WorldAI::ClassProfile::baseline_skill($archer), 'AC_DOUBLE', 'Archer baseline is Double Strafe');
is(WorldAI::ClassProfile::combat_style($archer), 'RANGED', 'Archer is ranged');

my $acolyte = WorldAI::ClassProfile::class_family(job_id => 4);
is($acolyte, 'ACOLYTE_FAMILY', 'job 4 is the Acolyte family');
is(WorldAI::ClassProfile::baseline_skill($acolyte), 'AL_HOLYLIGHT', 'Acolyte baseline is Holy Light');
is(WorldAI::ClassProfile::damage_type($acolyte), 'MAGIC', 'Acolyte is magic');
is(WorldAI::ClassProfile::baseline_element($acolyte), 'Holy', 'Acolyte baseline element is Holy');

is(WorldAI::ClassProfile::class_family(job_id => 0), 'UNSUPPORTED', 'Novice (job 0) is unsupported');
is(WorldAI::ClassProfile::class_family(job_id => 9999, job_name => 'High Wizard'), 'MAGE_FAMILY',
	'English job name supports custom server job IDs');
ok(!WorldAI::ClassProfile::profile('UNSUPPORTED'), 'UNSUPPORTED has no profile');

# baseline_skill_state: learned + slot + notMonsters gate
my $mage_state = WorldAI::ClassProfile::baseline_skill_state(
	family => 'MAGE_FAMILY',
	known_skills => { MG_FIREBOLT => 5 },
	attack_skill_slots => [{ index => 0, handle => 'MG_FIREBOLT', not_monsters => '' }],
	target_monster_name => 'Spore', target_monster_id => 1014,
);
ok($mage_state->{enabled}, 'learned + slotted Fire Bolt is enabled');
is($mage_state->{known_level}, 5, 'skill level is read');

my $mage_unlearned = WorldAI::ClassProfile::baseline_skill_state(
	family => 'MAGE_FAMILY',
	known_skills => {},
	attack_skill_slots => [{ index => 0, handle => 'MG_FIREBOLT', not_monsters => '' }],
	target_monster_name => 'Spore', target_monster_id => 1014,
);
ok(!$mage_unlearned->{enabled}, 'unlearned skill is not enabled');
is($mage_unlearned->{reason}, 'skill_not_learned', 'unlearned reason is explicit');

my $mage_blocked = WorldAI::ClassProfile::baseline_skill_state(
	family => 'MAGE_FAMILY',
	known_skills => { MG_FIREBOLT => 5 },
	attack_skill_slots => [{ index => 0, handle => 'MG_FIREBOLT', not_monsters => 'Spore, Rocker' }],
	target_monster_name => 'Spore', target_monster_id => 1014,
);
ok(!$mage_blocked->{enabled}, 'notMonsters excludes the target');
is($mage_blocked->{reason}, 'target_blocked_by_notMonsters', 'notMonsters reason is explicit');

done_testing();
