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
is($index->schema, 3, 'schema version is 3');
is($index->monster_count, 510, 'monster count');
is($index->map_count, 318, 'map count');
is($index->pair_count, 1920, 'monster-map candidate pair count');

is($index->monster(1002)->{name}, 'Poring', 'finds Poring by ID');
is($index->monster(1052)->{maps}{prt_fild07}, 80, 'Rocker spawn count is correct');

# --- monster Mode (schema 3) ---
my $poring_mode = $index->mode(1002);
ok($poring_mode, 'Poring has a mode object');
is($poring_mode->{can_move} ? 1 : 0, 1, 'Poring can move');
is($poring_mode->{aggressive} ? 1 : 0, 0, 'Poring is passive');
ok(defined($poring_mode->{mode_raw}) && $poring_mode->{mode_raw} =~ /^\d+$/, 'mode_raw is present');

my $scorpion_mode = $index->mode(1001);
is($scorpion_mode->{aggressive} ? 1 : 0, 1, 'Scorpion is aggressive');

# --- element table (schema 3) ---
ok($index->element_table, 'element table is present');
is($index->element_factor('Fire', 'Earth', 1), 150, 'Fire is strong vs Earth (Lv1)');
is($index->element_factor('Fire', 'Water', 1), 50, 'Fire is weak vs Water (Lv1)');
is($index->element_factor('Holy', 'Undead', 1), 150, 'Holy is strong vs Undead (Lv1)');
is($index->element_factor('Holy', 'Dark', 1), 125, 'Holy is strong vs Dark (Lv1)');
is($index->element_factor('Fire', 'Neutral', 1), 100, 'neutral match is 100');

my @rocker = $index->find_monsters('ROCKER');
is(scalar(@rocker), 1, 'AegisName lookup is case-insensitive');
is($rocker[0]{id}, 1052, 'AegisName resolves Rocker');

my @goblins = $index->find_monsters('Goblin');
is(scalar(@goblins), 5, 'ambiguous display name returns all matches');

# --- invalid reload retains previous index ---
my ($bad_fh, $bad_path) = tempfile();
print {$bad_fh} "{broken json\n";
close $bad_fh;
my $old_state_count = $index->monster_count;
$index->{path} = $bad_path;
my ($bad_ok, $bad_error) = $index->reload();
ok(!$bad_ok, 'invalid reload fails');
like($bad_error, qr/invalid JSON/, 'invalid reload explains the error');
is($index->monster_count, $old_state_count, 'invalid reload retains previous index');

# --- old schema is explicitly rejected ---
my ($old_fh, $old_path) = tempfile();
print {$old_fh} '{"meta":{"schema_version":2},"monsters":{},"maps":{},"element_table":{}}';
close $old_fh;
$index->{path} = $old_path;
my ($old_ok, $old_error) = $index->reload();
ok(!$old_ok, 'old schema 2 index is rejected');
like($old_error, qr/unsupported schema_version/, 'old schema rejection is explicit');
is($index->monster_count, $old_state_count, 'old schema rejection retains previous index');

done_testing();
