#!/usr/bin/env ruby
require 'yaml'
require 'json'
abort 'usage: generate_item_catalog.rb RATHENA_ROOT OUTPUT' unless ARGV.length == 2
root, output = ARGV
items = {}
merge = lambda do |left, right|
  left.merge(right) { |_key, a, b| a.is_a?(Hash) && b.is_a?(Hash) ? merge.call(a, b) : b }
end
%w[pre-re/item_db_etc.yml pre-re/item_db_equip.yml pre-re/item_db_usable.yml import/item_db.yml].each do |relative|
  data = YAML.safe_load(File.read(File.join(root, 'db', relative)), aliases: true)
  (data['Body'] || []).each do |item|
    id = item.fetch('Id')
    items[id] = merge.call(items[id] || {}, item)
    items[id]['CustomOverride'] = true if relative.start_with?('import/')
  end
end
catalog = items.sort.to_h.transform_values do |item|
  item.select { |key, _| %w[Id Type Locations Trade CustomOverride].include?(key) }
end
rows = catalog.map { |id, meta| "  #{JSON.generate(id.to_s)}: #{JSON.generate(meta)}" }
File.write(output, "{\n" + rows.join(",\n") + "\n}\n")
warn "generated #{catalog.size} item records"
