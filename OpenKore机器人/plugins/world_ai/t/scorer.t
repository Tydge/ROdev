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

done_testing();
