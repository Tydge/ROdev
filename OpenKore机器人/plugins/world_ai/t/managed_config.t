use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
	local $/;
	return <$fh>;
}

my $project_root = File::Spec->rel2abs(File::Spec->catdir($RealBin, '..', '..', '..', '..'));
my $instances = File::Spec->catdir($project_root, 'OpenKore机器人', 'instances');

my $swordman = slurp(File::Spec->catfile($instances, 'bot02', 'config.txt.template'));
my $mage = slurp(File::Spec->catfile($instances, 'bot03', 'config.txt.template'));
my $archer = slurp(File::Spec->catfile($instances, 'bot04', 'config.txt.template'));

ok(index($swordman, 'SM_BASH 10') < index($swordman, 'SM_SWORD 10'),
	'Swordman learns Bash before weapon mastery');
ok(index($mage, 'MG_FIREBOLT 10') < index($mage, 'MG_SRECOVERY 7'),
	'Mage learns Fire Bolt before passive recovery');
ok(index($archer, 'AC_DOUBLE 10') < index($archer, 'AC_OWL 10'),
	'Archer learns Double Strafe before passive accuracy');

like($archer, qr/buyAuto 1750 \{.*?npc prt_in 126 76.*?price 1.*?minAmount 200.*?maxAmount 1000.*?\}/s,
	'Archer automatically replenishes standard arrows from the Prontera Tool Dealer');

my $items_control = slurp(File::Spec->catfile($instances, 'shared-control', 'items_control.txt'));
like($items_control, qr/^Arrow 1000 0 0\b/m, 'shared inventory policy retains arrows');
like($items_control, qr/^"Rod \[3\]" 1 0 1\b/m, 'future Mage weapon is retained across Novice auto-gearing');

my $starter = slurp(File::Spec->catfile($project_root, '服务端补丁', 'npc', 'custom', 'novice_starter_pack.txt'));
like($starter, qr/Class == Job_Novice && !RODEV_NOVICE_STARTER_V1/,
	'starter grant is limited to Novices and protected by a one-time character flag');
like($starter, qr/set Zeny, Zeny \+ 5000;/, 'starter grant includes 5,000 Zeny');
like($starter, qr/getitem 501, 100;/, 'starter grant includes 100 Red Potions');
like($starter, qr/getitem 1243, 1;/, 'starter grant includes Novice Main-Gauche');

done_testing();
