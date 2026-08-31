use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempfile);
use Test::More;

use lib File::Spec->catdir($RealBin, '..', 'lib');
use WorldAI::Index;

my $index_path = File::Spec->catfile($RealBin, '..', 'map_index.json');
my $index = WorldAI::Index->new(path => $index_path);
my ($ok, $error) = $index->reload();
ok($ok, 'loads the repository index') or diag($error // 'unknown');
is($index->schema, 2, 'schema version is 2');
is($index->monster_count, 510, 'monster count');
is($index->map_count, 318, 'map count');
is($index->pair_count, 1920, 'monster-map candidate pair count');

is($index->monster(1002)->{name}, 'Poring', 'finds Poring by ID');
is($index->monster(1052)->{maps}{prt_fild07}, 80, 'Rocker spawn count is correct');

my @rocker = $index->find_monsters('ROCKER');
is(scalar(@rocker), 1, 'AegisName lookup is case-insensitive');
is($rocker[0]{id}, 1052, 'AegisName resolves Rocker');

my @goblins = $index->find_monsters('Goblin');
is(scalar(@goblins), 5, 'ambiguous display name returns all matches');

my ($bad_fh, $bad_path) = tempfile();
print {$bad_fh} "{broken json\n";
close $bad_fh;
my $old_state_count = $index->monster_count;
$index->{path} = $bad_path;
my ($bad_ok, $bad_error) = $index->reload();
ok(!$bad_ok, 'invalid reload fails');
like($bad_error, qr/invalid JSON/, 'invalid reload explains the error');
is($index->monster_count, $old_state_count, 'invalid reload retains previous index');

done_testing();
