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

done_testing();
