use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;

use lib File::Spec->catdir($RealBin, '..', 'lib');
use WorldAI::Index;
use WorldAI::CombatEstimate;
use WorldAI::ClassProfile;

my $index = WorldAI::Index->new(
	path => File::Spec->catfile($RealBin, '..', 'map_index.json'),
);
my ($loaded, $load_error) = $index->reload();
ok($loaded, 'fixture index loads') or BAIL_OUT($load_error // 'unknown');

my $ce = WorldAI::CombatEstimate->new();

sub est {
	my (%args) = @_;
	return $ce->estimate(
		snapshot        => $args{snapshot},
		monster         => $args{monster},
		profile         => $args{profile},
		skill_state     => $args{skill_state},
		known_skills    => $args{known_skills} || {},
		element_table   => $index->element_table,
		archer_has_ammo => defined($args{archer_has_ammo}) ? $args{archer_has_ammo} : 1,
	);
}

my $mage_profile = WorldAI::ClassProfile::profile('MAGE_FAMILY');
my $firebolt = { handle => 'MG_FIREBOLT', known_level => 6, enabled => 1 };

# --- 1. Mage uses MATK, not the low physical ATK ---
my $mage_snapshot = {
	base_level       => 30,
	attack_total     => 30,   # weak wand physical ATK
	attack_magic_avg => 150,
	sp               => 100,
	sp_max           => 200,
};
my $earth_monster = { id => 9991, name => 'EarthDummy', hp => 1000, defense => 20, magic_defense => 5,
	element => 'Earth', element_level => 1, attack => 50, attack2 => 60, attack_range => 1, level => 30 };
my $mage_est = est(snapshot => $mage_snapshot, monster => $earth_monster, profile => $mage_profile, skill_state => $firebolt);
is($mage_est->{estimate_mode}, 'MAGIC_SKILL', 'Mage with Fire Bolt uses MAGIC_SKILL');
is($mage_est->{damage_type}, 'MAGIC', 'Mage damage type is magic');
is($mage_est->{raw_power}, 150, 'Mage power source is MATK');
is($mage_est->{degraded}, 0, 'Mage estimate is not degraded');
ok($mage_est->{estimated_kill_cost} < 20, 'Mage kill cost is well under the physical 20 cap');
like(join(' ', @{$mage_est->{reasons}}), qr/MATK proxy/, 'Mage reason mentions MATK');

# --- 2. MATK missing never falls back to wand physical ATK ---
my $no_matk_snapshot = { %$mage_snapshot, attack_magic_avg => undef };
my $no_matk_est = est(snapshot => $no_matk_snapshot, monster => $earth_monster, profile => $mage_profile, skill_state => $firebolt);
is($no_matk_est->{estimate_mode}, 'MAGIC_DEGRADED', 'missing MATK degrades the magic estimate');
is($no_matk_est->{degraded}, 1, 'degraded flag is set');
isnt($no_matk_est->{raw_power}, 30, 'degraded magic does not reuse physical ATK');

# --- 3. DEF penalizes physical, MDEF penalizes magic ---
my $tanky_monster = { %$earth_monster, defense => 80, magic_defense => 5 };
my $sword_profile = WorldAI::ClassProfile::profile('SWORDMAN_FAMILY');
my $sword_state = { handle => 'SM_BASH', known_level => 10, enabled => 1 };
my $sword_est = est(snapshot => { base_level => 30, attack_total => 100, sp => 200, sp_max => 200 },
	monster => $tanky_monster, profile => $sword_profile, skill_state => $sword_state);
my $mage_tanky = est(snapshot => $mage_snapshot, monster => $tanky_monster, profile => $mage_profile, skill_state => $firebolt);
ok($sword_est->{defense_penalty} > $mage_tanky->{defense_penalty},
	'high DEF hurts the physical class more than the magic class');
like(join(' ', @{$sword_est->{reasons}}), qr/high monster DEF/, 'physical class reports DEF penalty');

# --- 4. element ordering: favorable > neutral > unfavorable ---
my $fire_neutral = est(snapshot => $mage_snapshot, monster => { %$earth_monster, element => 'Neutral' }, profile => $mage_profile, skill_state => $firebolt);
my $fire_earth   = est(snapshot => $mage_snapshot, monster => { %$earth_monster, element => 'Earth' }, profile => $mage_profile, skill_state => $firebolt);
my $fire_water   = est(snapshot => $mage_snapshot, monster => { %$earth_monster, element => 'Water' }, profile => $mage_profile, skill_state => $firebolt);
ok($fire_earth->{element_factor} > $fire_neutral->{element_factor}, 'Fire vs Earth is favorable');
ok($fire_neutral->{element_factor} > $fire_water->{element_factor}, 'Fire vs Water is unfavorable');
ok($fire_earth->{element_factor} > $fire_water->{element_factor}, 'favorable > unfavorable for Fire');
ok($fire_earth->{effective_power} > $fire_water->{effective_power}, 'element multiplies effective power');
ok($fire_earth->{estimated_kill_cost} < $fire_water->{estimated_kill_cost}, 'element flows into kill cost');

# --- 5. Archer without arrows does not claim Double Strafe ---
my $archer_profile = WorldAI::ClassProfile::profile('ARCHER_FAMILY');
my $ds = { handle => 'AC_DOUBLE', known_level => 10, enabled => 1 };
my $archer_no_arrow = est(snapshot => { base_level => 30, attack_total => 120, sp => 200, sp_max => 200 },
	monster => $earth_monster, profile => $archer_profile, skill_state => $ds, archer_has_ammo => 0);
is($archer_no_arrow->{estimate_mode}, 'PHYSICAL_NORMAL', 'no arrows disables Double Strafe estimate');
like(join(' ', @{$archer_no_arrow->{reasons}}), qr/no arrows/, 'no-arrow reason is explicit');

my $archer_with_arrow = est(snapshot => { base_level => 30, attack_total => 120, sp => 200, sp_max => 200 },
	monster => $earth_monster, profile => $archer_profile, skill_state => $ds, archer_has_ammo => 1);
is($archer_with_arrow->{estimate_mode}, 'PHYSICAL_SKILL', 'arrows enable Double Strafe estimate');

# --- 6. Unlearned skill cannot fake magic ---
my $mage_unlearned = est(snapshot => $mage_snapshot, monster => $earth_monster, profile => $mage_profile, skill_state => { handle => 'MG_FIREBOLT', known_level => 0, enabled => 0 });
is($mage_unlearned->{estimate_mode}, 'PHYSICAL_NORMAL', 'unlearned Fire Bolt degrades to normal attack');
is($mage_unlearned->{damage_type}, 'PHYSICAL', 'degraded Mage counts as physical');

# --- 7. Thief Double Attack passive gives a limited expected-output bonus ---
my $thief_profile = WorldAI::ClassProfile::profile('THIEF_FAMILY');
my $thief_no_passive = est(snapshot => { base_level => 30, attack_total => 100 },
	monster => $earth_monster, profile => $thief_profile, known_skills => {});
my $thief_passive = est(snapshot => { base_level => 30, attack_total => 100 },
	monster => $earth_monster, profile => $thief_profile, known_skills => { TF_DOUBLE => 10 });
ok($thief_passive->{effective_power} > $thief_no_passive->{effective_power}, 'Double Attack raises effective power');
ok($thief_passive->{effective_power} <= $thief_no_passive->{effective_power} * 1.5,
	'Double Attack never becomes a constant 2x output');
like(join(' ', @{$thief_passive->{reasons}}), qr/TF_DOUBLE/, 'Double Attack passive is reported');

done_testing();
