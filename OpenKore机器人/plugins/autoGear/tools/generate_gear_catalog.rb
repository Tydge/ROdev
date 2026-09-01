#!/usr/bin/env ruby

require "yaml"

# rAthena job names that differ from OpenKore's %jobs_lut spellings.
# The catalog is consumed by OpenKore's autoGear, so translate to OpenKore names.
JOB_NAME_MAP = {
  "Swordman" => "Swordsman",
}.freeze

abort "usage: generate_gear_catalog.rb ITEM_DB_EQUIP_YML OUTPUT" unless ARGV.length == 2

source, output = ARGV
database = YAML.safe_load(File.read(source), aliases: true)
items = database.fetch("Body")

File.open(output, "w") do |file|
  file.puts "# id\ttype\tsubtype\tattack\tmagic_attack\tdefense\tmagic_defense\tslots\tweapon_level\tequip_level\tjobs\tlocations\tname\tscripted"

  items.each do |item|
    jobs = (item["Jobs"] || {}).select { |_name, enabled| enabled }.keys
      .map { |name| JOB_NAME_MAP.fetch(name, name) }
      .sort.join(",")
    locations = (item["Locations"] || {}).select { |_name, enabled| enabled }.keys.sort.join(",")
    name = item.fetch("Name", "").to_s.tr("\t\r\n", "   ")
    fields = [
      item.fetch("Id"), item.fetch("Type", ""), item.fetch("SubType", ""),
      item.fetch("Attack", 0), item.fetch("MagicAttack", 0),
      item.fetch("Defense", 0), item.fetch("MagicDefense", 0),
      item.fetch("Slots", 0), item.fetch("WeaponLevel", 0),
      item.fetch("EquipLevelMin", 0), jobs, locations, name,
      item.key?("Script") ? 1 : 0
    ]
    file.puts fields.join("\t")
  end
end

warn "generated #{items.length} equipment entries at #{output}"
