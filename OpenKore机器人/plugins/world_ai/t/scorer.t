use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($RealBin, '..', 'lib');
use WorldAI::Index;
use WorldAI::Scorer;

my $index = WorldAI::Index->new(
	path => File::Spec->catfile($RealBin, '..', 'map_index.json'),
);
my ($loaded, $load_error) = $index->reload();
ok($loaded, 'fixture index loads') or BAIL_OUT($load_error // 'unknown');

my $scorer = WorldAI::Scorer->new();
my $snapshot = {
	base_level   => 8,
	hp           => 310,
	hp_max       => 310,
	attack_total => 40,
};

my $rocker = $index->monster(1052);
my $rocker_map = $index->map_spawns('prt_fild07');
my $rocker_profile = $scorer->prepare_map_profile(
	$snapshot, 'prt_fild07', $rocker_map, sub { $index->monster($_[0]) },
);
my $rocker_result = $scorer->score_candidate(
	$snapshot, $rocker, 'prt_fild07', 80, $rocker_profile,
);
ok($rocker_result->{allowed}, 'Rocker is allowed for the level 8 fixture');
ok(defined($rocker_result->{score}), 'allowed candidate has a score');
ok($rocker_result->{breakdown}{map_risk} > 0, 'Vocal creates co-spawn map risk');
is($rocker_result->{route_reachability}, 'UNVERIFIED', 'route is not falsely claimed reachable');

my $vocal = $index->monster(1088);
my ($vocal_allowed, $vocal_reasons) = $scorer->hard_filter($snapshot, $vocal, 'prt_fild07');
ok(!$vocal_allowed, 'Vocal is filtered for the level 8 fixture');
like(join(' ', @{$vocal_reasons}), qr/level|kill cost/, 'Vocal filter is explained');

my $beelzebub = $index->monster(1873);
my ($boss_allowed, $boss_reasons) = $scorer->hard_filter($snapshot, $beelzebub, 'abbey03');
ok(!$boss_allowed, 'boss_spawn_maps excludes Beelzebub despite is_mvp=false');
like(join(' ', @{$boss_reasons}), qr/boss spawn/, 'boss-spawn exclusion is explained');

my $poring = $index->monster(1002);
my $poring_map = $index->map_spawns('prt_fild08');
my $poring_profile = $scorer->prepare_map_profile(
	$snapshot, 'prt_fild08', $poring_map, sub { $index->monster($_[0]) },
);
my $first = $scorer->score_candidate($snapshot, $poring, 'prt_fild08', 70, $poring_profile);
my $second = $scorer->score_candidate($snapshot, $poring, 'prt_fild08', 70, $poring_profile);
is($first->{score}, $second->{score}, 'same input produces a stable score');

# --- Novice penalty (job_id == 0) ---
# A level-12 Novice (weak attack, ~100 HP) must not be sent against
# Baby Desert Wolf: attack 36 exceeds the novice cap and its kill cost /
# single-hit damage both exceed the tightened novice thresholds.
my $novice_snapshot = {
	base_level   => 12,
	job_id       => 0,
	hp_max       => 100,
	attack_total => 10,
};

my $bwolf = $index->monster(1107);
my ($bwolf_novice_allowed, $bwolf_novice_reasons) = $scorer->hard_filter($novice_snapshot, $bwolf, 'moc_fild01');
ok(!$bwolf_novice_allowed, 'Novice is filtered from Baby Desert Wolf');
like(join(' ', @{$bwolf_novice_reasons}), qr/novice/, 'Novice filter reasons are explained');

my ($poring_novice_allowed, $poring_novice_reasons) = $scorer->hard_filter($novice_snapshot, $poring, 'prt_fild08');
ok($poring_novice_allowed, 'Novice is still allowed Poring')
	or diag('Poring was blocked for Novice: ' . join('; ', @{$poring_novice_reasons}));

my ($lunatic_novice_allowed, $lunatic_novice_reasons) = $scorer->hard_filter($novice_snapshot, $index->monster(1063), 'prt_fild08');
ok($lunatic_novice_allowed, 'Novice is still allowed Lunatic')
	or diag('Lunatic was blocked for Novice: ' . join('; ', @{$lunatic_novice_reasons}));

# The same level-12 character as a first job still gets the normal policy.
my $thief_snapshot = {
	base_level   => 12,
	job_id       => 6,
	hp_max       => 310,
	attack_total => 40,
};
my ($bwolf_thief_allowed, $bwolf_thief_reasons) = $scorer->hard_filter($thief_snapshot, $bwolf, 'moc_fild01');
ok($bwolf_thief_allowed, 'first-job character is still allowed Baby Desert Wolf')
	or diag('Baby Desert Wolf was blocked for Thief: ' . join('; ', @{$bwolf_thief_reasons}));

# Live regression: EthanRowe had 81 total attack at Base 27. Savage needs about
# 26 estimated normal attacks and produced repeated deaths with zero kills, so it
# must no longer pass the normal first-job hard filter.
my $swordman_snapshot = {
	base_level   => 27,
	job_id       => 1,
	hp_max       => 504,
	attack_total => 81,
};
my $savage = $index->monster(1166);
my ($savage_allowed, $savage_reasons) = $scorer->hard_filter($swordman_snapshot, $savage, 'prt_fild10');
ok(!$savage_allowed, 'repeatedly fatal Savage target is filtered for the live Swordman baseline');
like(join(' ', @{$savage_reasons}), qr/kill cost/, 'Savage rejection explains excessive kill cost');

# --- Step 4A.2: class-aware scoring ---
sub fake_map_profile { return { total => 0, contributions => {} }; }

my $dummy = {
	id => 9991, name => 'EarthDummy', level => 30, hp => 1000,
	base_exp => 500, job_exp => 400, defense => 20, magic_defense => 5,
	element => 'Earth', element_level => 1, attack => 40, attack2 => 50,
	attack_range => 1, is_mvp => 0, boss_spawn_maps => [],
};

# 1. Key regression: Mage with weak physical ATK but real MATK + Fire Bolt is not blocked.
$scorer->set_combat_context(
	known_skills       => { MG_FIREBOLT => 6 },
	attack_skill_slots => [{ index => 0, handle => 'MG_FIREBOLT', not_monsters => '' }],
	element_table      => $index->element_table,
);
my $mage_snapshot = {
	base_level => 30, job_id => 2, job_name => 'Mage',
	hp => 500, hp_max => 500, sp => 100, sp_max => 200,
	attack_total => 30, attack_magic_avg => 150,
};
my ($mage_allowed, $mage_reasons) = $scorer->hard_filter($mage_snapshot, $dummy, 'test_map');
ok($mage_allowed, 'Mage with Fire Bolt is not blocked by low physical ATK')
	or diag('Mage was blocked: ' . join('; ', @{$mage_reasons}));
my $mage_scored = $scorer->score_candidate($mage_snapshot, $dummy, 'test_map', 10, fake_map_profile());
is($mage_scored->{estimate_mode}, 'MAGIC_SKILL', 'Mage candidate uses magic estimate');

# 2. DEF penalizes physical, MDEF penalizes magic.
my $tanky = { %$dummy, defense => 80, magic_defense => 5 };
my $mage_tanky = $scorer->score_candidate($mage_snapshot, $tanky, 'test_map', 10, fake_map_profile());

$scorer->set_combat_context(
	known_skills       => { SM_BASH => 10 },
	attack_skill_slots => [{ index => 0, handle => 'SM_BASH', not_monsters => '' }],
	element_table      => $index->element_table,
);
my $sword_snapshot = {
	base_level => 30, job_id => 1, job_name => 'Swordman',
	hp => 800, hp_max => 800, sp => 200, sp_max => 200, attack_total => 100,
};
my $sword_tanky = $scorer->score_candidate($sword_snapshot, $tanky, 'test_map', 10, fake_map_profile());
ok($sword_tanky->{breakdown}{defense_penalty} > $mage_tanky->{breakdown}{defense_penalty},
	'high DEF penalizes the physical class more than the magic class');

# 3. Element ordering for Fire.
$scorer->set_combat_context(
	known_skills       => { MG_FIREBOLT => 6 },
	attack_skill_slots => [{ index => 0, handle => 'MG_FIREBOLT', not_monsters => '' }],
	element_table      => $index->element_table,
);
my $fire_earth = $scorer->score_candidate($mage_snapshot, { %$dummy, element => 'Earth' }, 'test_map', 10, fake_map_profile());
my $fire_water = $scorer->score_candidate($mage_snapshot, { %$dummy, element => 'Water' }, 'test_map', 10, fake_map_profile());
ok($fire_earth->{element_factor} > $fire_water->{element_factor},
	'Fire Bolt sees favorable factor vs Earth, unfavorable vs Water');
ok($fire_earth->{score} > $fire_water->{score},
	'element flows into score via kill_cost: Earth ranks above Water');

# 4. Ranged risk: melee suffers more than ranged, but ranged risk stays positive.
$scorer->set_combat_context(known_skills => {}, attack_skill_slots => [], element_table => $index->element_table);
my $ranged_monster = { %$dummy, attack_range => 3 };
my $melee_est = $scorer->score_candidate($sword_snapshot, $ranged_monster, 'test_map', 10, fake_map_profile());
my $ranged_snap = { %$sword_snapshot, job_id => 3, job_name => 'Archer' };
my $ranged_est = $scorer->score_candidate($ranged_snap, $ranged_monster, 'test_map', 10, fake_map_profile());
ok($melee_est->{breakdown}{target_risk} > $ranged_est->{breakdown}{target_risk},
	'melee suffers more range risk than ranged');
ok($ranged_est->{breakdown}{target_risk} > 0, 'ranged range risk is still positive');

# 5. Vulnerability: broke + low HP tightens safety and inflates risk.
$scorer->set_combat_context(known_skills => {}, attack_skill_slots => [], element_table => $index->element_table);
my $healthy = { base_level => 30, job_id => 1, job_name => 'Swordman',
	hp => 800, hp_max => 800, zeny => 1000, red_potion_count => 10, attack_total => 100 };
my $broke = { %$healthy, hp => 200, hp_max => 800, zeny => 10, red_potion_count => 0 };
my $agg_monster = { %$dummy, attack => 150, attack2 => 150, mode => { aggressive => 1 } };
my ($b_allowed, $b_reasons) = $scorer->hard_filter($broke, $agg_monster, 'test_map');
ok(!$b_allowed, 'broke+lowHP bot rejects aggressive monster');
ok((grep { /aggressive/ } @{$b_reasons}), 'aggressive rejection reason is explicit');

my $hitter = { %$dummy, attack => 150, attack2 => 150 };
my $h_scored = $scorer->score_candidate($healthy, $hitter, 'test_map', 10, fake_map_profile());
my $b_scored = $scorer->score_candidate($broke, $hitter, 'test_map', 10, fake_map_profile());
ok($b_scored->{breakdown}{target_risk} > $h_scored->{breakdown}{target_risk},
	'vulnerable bot inflates target risk vs healthy bot');
ok($b_scored->{score} < $h_scored->{score}, 'vulnerable bot scores dangerous target lower');

done_testing();
