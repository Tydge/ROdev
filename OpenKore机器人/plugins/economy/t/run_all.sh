#!/bin/sh
set -eu
# Absolute paths also allow macOS hardened Perl to load OpenKore XSTools.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
openkore_root=$(CDPATH= cd -- "$1" && pwd)
rathena_root=$(CDPATH= cd -- "$2" && pwd)
sh "$script_dir/run_npc_allowlist.sh" "$openkore_root" "$rathena_root"
PERL5LIB="$openkore_root/src:$openkore_root/src/deps" prove \
  "$script_dir/inventory.t" "$script_dir/trade.t" \
  "$script_dir/trade_adapter.t" "$script_dir/trade_request_error.t"
