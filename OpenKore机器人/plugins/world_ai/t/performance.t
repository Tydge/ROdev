use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;
use Time::HiRes qw(time);

use lib File::Spec->catdir($RealBin, '..', 'lib');
use WorldAI::Index;
use WorldAI::Scorer;

my $index = WorldAI::Index->new(
	path => File::Spec->catfile($RealBin, '..', 'map_index.json'),
);
my ($loaded, $error) = $index->reload();
ok($loaded, 'performance fixture loads') or BAIL_OUT($error // 'unknown');

my $snapshot = {
	base_level   => 8,
	hp           => 310,
	hp_max       => 310,
	attack_total => 40,
};
my $scorer = WorldAI::Scorer->new();
my %profiles;
my $scored = 0;
my $started = time;

for my $id ($index->monster_ids) {
	my $monster = $index->monster($id);
	for my $map (sort keys %{$monster->{maps}}) {
		$profiles{$map} ||= $scorer->prepare_map_profile(
			$snapshot,
			$map,
			$index->map_spawns($map),
			sub { $index->monster($_[0]) },
		);
		$scorer->score_candidate(
			$snapshot, $monster, $map, $monster->{maps}{$map}, $profiles{$map},
		);
		$scored++;
	}
}

my $elapsed = time - $started;
is($scored, 1920, 'full candidate set was scored');
cmp_ok($elapsed, '<', 1.0, sprintf('full score is below one second (%.4fs)', $elapsed));
diag(sprintf('full_score_candidates=%d maps=%d elapsed_ms=%.2f',
	$scored, scalar(keys %profiles), $elapsed * 1000));

done_testing();
