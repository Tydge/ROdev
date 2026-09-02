use strict;
use warnings;

use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../lib";

use WorldAI::CombatPolicy;

my $policy = WorldAI::CombatPolicy->new();

sub decide {
	my (%args) = @_;
	my $handle = $args{handle};
	return $policy->evaluate(
		job_id => $args{job_id},
		job_name => $args{job_name},
		known_skills => $args{known_skills} || {},
		attack_skill_slots => defined($handle) ? [{
			index => 0, handle => $handle, not_monsters => $args{not_monsters},
		}] : [],
		target_monster_name => exists($args{target}) ? $args{target} : 'Spore',
		target_monster_id => 1014,
		target_map => 'pay_fild01',
	);
}

my $mage = decide(job_id => 2, handle => 'MG_FIREBOLT', known_skills => { MG_FIREBOLT => 5 });
is($mage->{class_family}, 'MAGE_FAMILY', 'Mage maps to the Mage family');
is($mage->{mode}, 'SINGLE_TARGET', 'learned and configured Fire Bolt enables single-target mode');
ok($mage->{skills}[0]{enabled}, 'Fire Bolt is enabled');
is_deeply($mage->{skills}[0]{slots}, [0], 'the configured Fire Bolt slot is selected');
ok($mage->{fallback_normal_attack}, 'normal attack fallback always remains on');

my $unlearned = decide(job_id => 2, handle => 'MG_FIREBOLT');
ok(!$unlearned->{skills}[0]{enabled}, 'unlearned Fire Bolt is not enabled');
is($unlearned->{skills}[0]{reason}, 'skill_not_learned', 'unlearned skill has an explicit reason');
is($unlearned->{mode}, 'NORMAL_ATTACK_BASELINE', 'unlearned skill falls back to normal attacks');

my $missing_slot = decide(job_id => 2, known_skills => { MG_FIREBOLT => 3 });
ok(!$missing_slot->{skills}[0]{enabled}, 'learned skill without a configured slot is not invented');
is($missing_slot->{skills}[0]{reason}, 'configured_attack_slot_missing', 'missing slot is explicit');

my $archer = decide(job_id => 11, handle => 'AC_DOUBLE', known_skills => { AC_DOUBLE => 10 }, target => 'Rocker');
ok($archer->{skills}[0]{enabled}, 'Hunter family enables configured Double Strafe');

my $acolyte = decide(job_id => 4, handle => 'AL_HOLYLIGHT', known_skills => { AL_HOLYLIGHT => 1 });
ok($acolyte->{skills}[0]{enabled}, 'Acolyte enables configured Holy Light');

my $swordman = decide(job_id => 1, handle => 'SM_BASH', known_skills => { SM_BASH => 7 });
ok($swordman->{skills}[0]{enabled}, 'Swordman enables configured Bash');

my $thief = decide(job_id => 12, known_skills => { TF_DOUBLE => 10 });
is($thief->{class_family}, 'THIEF_FAMILY', 'Assassin maps to the Thief family');
is($thief->{mode}, 'NORMAL_ATTACK_BASELINE', 'Thief family deliberately uses normal attack baseline');
is_deeply($thief->{skills}, [], 'Thief policy does not invent an active skill');

my $blocked = decide(
	job_id => 2, handle => 'MG_FIREBOLT', known_skills => { MG_FIREBOLT => 5 },
	not_monsters => 'Spore, Rocker',
);
ok(!$blocked->{skills}[0]{enabled}, 'notMonsters conflict is not overridden');
is($blocked->{skills}[0]{reason}, 'target_blocked_by_notMonsters', 'notMonsters conflict is explained');

my $no_target = decide(job_id => 3, handle => 'AC_DOUBLE', known_skills => { AC_DOUBLE => 5 }, target => '');
ok(!$no_target->{skills}[0]{enabled}, 'recommendation without an executed target does not change combat');
is($no_target->{skills}[0]{reason}, 'executed_target_unavailable', 'missing executed target is explicit');

is($policy->class_family(job_id => 9999, job_name => 'High Wizard'), 'MAGE_FAMILY',
	'English job name supports custom server job IDs');

done_testing;
