package autoGear;

use strict;
use Plugins;
use Globals qw(%config $char $net %jobs_lut);
use Log qw(message warning debug);
use Settings;
use Time::HiRes qw(time);
use AI;
use File::Basename qw(dirname);

our $name = 'autoGear';
my %catalog;
my $next_check = 0;
my $plugin_dir = $Plugins::current_plugin_folder || dirname(__FILE__);

Plugins::register($name, 'Choose sensible equipment upgrades from inventory', \&on_unload);

my $hooks = Plugins::addHooks(
	['start3',                       \&load_catalog],
	['postloadfiles',                \&load_catalog],
	['inventory_ready',              \&request_check],
	['packet/inventory_item_added',  \&request_check],
	['job_changed',                  \&request_check],
	['unequipped_item',              \&request_check],
	['AI_pre',                       \&on_ai_pre],
);

sub on_unload {
	Plugins::delHooks($hooks);
}

sub normalize {
	my $value = lc($_[0] // '');
	$value =~ s/[^a-z0-9]//g;
	return $value;
}

sub load_catalog {
	my $filename = "$plugin_dir/gear_catalog.txt";
	%catalog = ();

	unless ($filename && -f $filename) {
		warning "[autoGear] gear_catalog.txt was not found; automatic equipment is disabled.\n";
		return;
	}

	open my $file, '<', $filename or do {
		warning "[autoGear] cannot read $filename: $!\n";
		return;
	};

	while (my $line = <$file>) {
		chomp $line;
		next if $line =~ /^\s*(?:#|$)/;
		my @field = split /\t/, $line, 14;
		next unless @field == 14;

		my ($id, $type, $subtype, $attack, $magic_attack, $defense,
			$magic_defense, $slots, $weapon_level, $equip_level,
			$jobs, $locations, $item_name, $scripted) = @field;

		$catalog{$id} = {
			type          => $type,
			subtype       => $subtype,
			attack        => 0 + $attack,
			magic_attack  => 0 + $magic_attack,
			defense       => 0 + $defense,
			magic_defense => 0 + $magic_defense,
			slots         => 0 + $slots,
			weapon_level  => 0 + $weapon_level,
			equip_level   => 0 + $equip_level,
			jobs          => { map { normalize($_) => 1 } grep { length } split /,/, $jobs },
			locations     => { map { $_ => 1 } grep { length } split /,/, $locations },
			name          => $item_name,
			scripted      => 0 + $scripted,
		};
	}
	close $file;
	message sprintf("[autoGear] Loaded %d equipment records.\n", scalar keys %catalog), 'success';
	request_check();
}

sub request_check {
	$next_check = 0;
}

sub current_job_keys {
	my $job = normalize($jobs_lut{$char->{jobID}} // '');
	my %aliases = (
		highnovice => 'novice', highwizard => 'wizard', whitesmith => 'blacksmith',
		lordknight => 'knight', highpriest => 'priest', sniper => 'hunter',
		assassincross => 'assassin', paladin => 'crusader', champion => 'monk',
		professor => 'sage', stalker => 'rogue', creator => 'alchemist',
		clown => 'barddancer', gypsy => 'barddancer', babybard => 'barddancer',
		babydancer => 'barddancer', supernovice => 'supernovice',
	);
	my $family = $aliases{$job} // $job;
	return ($job, $family);
}

sub job_can_use {
	my ($meta) = @_;
	return 1 unless keys %{$meta->{jobs}};
	return 1 if $meta->{jobs}{all};
	my ($job, $family) = current_job_keys();
	return $meta->{jobs}{$job} || $meta->{jobs}{$family};
}

sub supports_slot {
	my ($meta, $slot) = @_;
	my %location_for = (
		rightHand => [qw(Right_Hand Both_Hand)],
		leftHand  => [qw(Left_Hand)],
		armor     => [qw(Armor)],
		robe      => [qw(Garment)],
		shoes     => [qw(Shoes)],
		topHead   => [qw(Head_Top)],
		midHead   => [qw(Head_Mid)],
		lowHead   => [qw(Head_Low)],
	);
	return 0 unless $location_for{$slot};
	for my $location (@{$location_for{$slot}}) {
		return 1 if $meta->{locations}{$location};
	}
	return 0;
}

sub has_cards_or_forge_data {
	my ($item) = @_;
	return 0 unless defined $item->{cards} && length $item->{cards};
	for my $value (unpack('v*', $item->{cards})) {
		return 1 if $value;
	}
	return 0;
}

sub gear_score {
	my ($item, $meta) = @_;
	my $refine = 0 + ($item->{upgrade} // 0);
	my $role = lc($config{autoGear_role} // 'physical');
	my ($job) = current_job_keys();
	# Future casters still begin without spells. Let them use a normal starter
	# weapon as Novices, then switch to magic scoring after first job change.
	$role = 'physical' if $job eq 'novice';

	if ($meta->{type} eq 'Weapon') {
		my $primary = $role eq 'magic' ? $meta->{magic_attack} : $meta->{attack};
		my $secondary = $role eq 'magic' ? $meta->{attack} : $meta->{magic_attack};
		return $primary * 100 + $secondary * 20
			+ $refine * (100 + 50 * ($meta->{weapon_level} || 1))
			+ $meta->{slots} * 5;
	}

	return $meta->{defense} * 100 + $meta->{magic_defense} * 40
		+ $refine * 70 + $meta->{slots} * 5;
}

sub candidate_is_safe {
	my ($item, $meta, $slot) = @_;
	return 0 unless $item && $meta;
	return 0 if $item->{equipped};
	return 0 unless $item->equippable();
	return 0 unless $item->{identified};
	return 0 if $item->{broken};
	return 0 if $meta->{equip_level} > ($char->{lv} || 0);
	return 0 unless job_can_use($meta);
	return 0 unless supports_slot($meta, $slot);
	return 0 if $slot eq 'leftHand' && $meta->{type} eq 'Weapon';
	return 0 if ($config{autoGear_protectCarded} // 1) && has_cards_or_forge_data($item);
	return 1;
}

sub choose_one_upgrade {
	my @slots = qw(rightHand armor leftHand robe shoes topHead midHead lowHead);
	my $margin = 100 * (0 + ($config{autoGear_upgradeMargin} // 1));

	for my $slot (@slots) {
		my $current = $char->{equipment}{$slot};
		if ($current && ($config{autoGear_protectCarded} // 1) && has_cards_or_forge_data($current)) {
			next;
		}

		my $current_meta = $current ? $catalog{$current->{nameID}} : undef;
		# Unknown or custom equipped items are left alone because their script bonuses
		# cannot be scored safely from the standard catalog.
		next if $current && !$current_meta;
		my $current_score = $current ? gear_score($current, $current_meta) : -1;

		my ($best, $best_meta, $best_score);
		for my $item (@{$char->inventory->getItems}) {
			my $meta = $catalog{$item->{nameID}};
			next unless candidate_is_safe($item, $meta, $slot);
			my $score = gear_score($item, $meta);
			next if defined $best_score && $score <= $best_score;
			($best, $best_meta, $best_score) = ($item, $meta, $score);
		}

		next unless $best;
		next if $current && $best_score < $current_score + $margin;

		my $old_name = $current ? $current->{name} : '(empty)';
		message sprintf("[autoGear] %s: %s -> %s (score %d -> %d)\n",
			$slot, $old_name, $best->{name}, $current_score, $best_score), 'success';
		$best->equipInSlot($slot);
		return 1;
	}
	return 0;
}

sub on_ai_pre {
	return unless $config{autoGear};
	return unless $char && $net && $net->getState == Network::IN_GAME;
	return unless keys %catalog;
	return if time < $next_check;

	my $interval = 0 + ($config{autoGear_checkInterval} // 10);
	$interval = 3 if $interval < 3;
	$next_check = time + $interval;

	my $action = AI::action() // '';
	return if $action =~ /attack|skill|npc|sell|buy|storage|deal/;
	choose_one_upgrade();
}

# Also load immediately when the plugin is added to an already running bot.
load_catalog();

1;
