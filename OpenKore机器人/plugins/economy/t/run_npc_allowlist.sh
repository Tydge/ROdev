#!/bin/sh
set -eu
# Usage: run_npc_allowlist.sh OPENKORE_ROOT RATHENA_ROOT [ITEMS_CONTROL]
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
openkore_root=$(CDPATH= cd -- "$1" && pwd)
rathena_root=$(CDPATH= cd -- "$2" && pwd)
policy=${3:-"$script_dir/../../../instances/shared-control/items_control.txt"}
catalog=$(mktemp)
trap 'rm -f "$catalog"' EXIT HUP INT TERM
ruby -r yaml -r json -e '
  items = {}
  ARGV.each do |path|
    (YAML.safe_load(File.read(path), aliases: true)["Body"] || []).each do |item|
      items[item["Id"]] = (items[item["Id"]] || {}).merge(item)
    end
  end
  puts JSON.generate(items.values)
' "$rathena_root/db/pre-re/item_db_etc.yml" \
  "$rathena_root/db/pre-re/item_db_equip.yml" \
  "$rathena_root/db/pre-re/item_db_usable.yml" \
  "$rathena_root/db/import/item_db.yml" > "$catalog"
PERL5LIB="$openkore_root/src:$openkore_root/src/deps" \
  perl "$script_dir/npc_allowlist.t" "$policy" "$catalog"
