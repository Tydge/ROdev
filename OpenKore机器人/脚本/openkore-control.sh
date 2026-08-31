#!/bin/zsh

set -u

RO_ROOT="/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local"
OPENKORE_ROOT="$RO_ROOT/openkore"
BOT_INSTANCES_ROOT="$RO_ROOT/openkore-local/instances"
TABLE_OVERLAY="$RO_ROOT/openkore-local/tables"
MANAGED_PLUGIN_ROOT="/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/plugins"
RO_CONTROL="/Users/wangtaizhi/娱乐/RO本地服/自动化/ro-control.sh"
DB_SOCKET="$RO_ROOT/database/mariadb.sock"
BOT_ACCOUNT_PREFIX="openkore%"
BOT_IDS=(bot01 bot02 bot03 bot04 bot05)
SCRIPT_PATH="${0:A}"

if command -v mysql >/dev/null 2>&1; then
  MYSQL_BIN="$(command -v mysql)"
elif command -v mariadb >/dev/null 2>&1; then
  MYSQL_BIN="$(command -v mariadb)"
else
  MYSQL_BIN="/opt/homebrew/bin/mysql"
fi

screen_is_running() {
  local bot_id="$1"
  /usr/bin/screen -ls 2>/dev/null | /usr/bin/grep -qE "[.]ro-${bot_id}[[:space:]]"
}

db_ready() {
  [[ -S "$DB_SOCKET" ]] || return 1
  "$MYSQL_BIN" --no-defaults --socket="$DB_SOCKET" -uroot -e "SELECT 1;" >/dev/null 2>&1
}

ensure_managed_plugins() {
  local plugin_name="world_ai_test"
  local source_file="$MANAGED_PLUGIN_ROOT/$plugin_name/$plugin_name.pl"
  local target_dir="$OPENKORE_ROOT/plugins/$plugin_name"
  local target_file="$target_dir/$plugin_name.pl"

  [[ -f "$source_file" ]] || return 0
  /bin/mkdir -p "$target_dir"

  if [[ -L "$target_file" ]]; then
    /bin/ln -sfn "$source_file" "$target_file"
  elif [[ ! -e "$target_file" ]]; then
    /bin/ln -s "$source_file" "$target_file"
  else
    echo "[警告] 保留现有插件文件，未覆盖：$target_file"
  fi
}

start_bot_instance() {
  local bot_id="$1"
  local ai_mode="$2"
  local bot_root="$BOT_INSTANCES_ROOT/$bot_id"
  local session="ro-$bot_id"

  if [[ ! -d "$bot_root/control" ]]; then
    echo "[失败] 未找到实例配置：$bot_root/control"
    return 1
  fi

  if screen_is_running "$bot_id"; then
    echo "[OK] $bot_id 已在运行。"
    return 0
  fi

  ensure_managed_plugins

  echo "[启动] OpenKore $bot_id（AI: $ai_mode）"
  /usr/bin/screen -dmS "$session" /bin/zsh -lc \
    "cd '$OPENKORE_ROOT' && exec perl openkore.pl --ai '$ai_mode' --control='$bot_root/control' --tables='$TABLE_OVERLAY:$OPENKORE_ROOT/tables' --fields='$OPENKORE_ROOT/fields' --logs='$bot_root/logs'"

  sleep 2
  if screen_is_running "$bot_id"; then
    echo "[OK] $bot_id 已启动。查看控制台：$SCRIPT_PATH console $bot_id"
  else
    echo "[失败] $bot_id 启动后立即退出，请查看 $bot_root/logs"
    return 1
  fi
}

start_bots() {
  local ai_mode="$1"
  local bot_id
  for bot_id in "${BOT_IDS[@]}"; do
    start_bot_instance "$bot_id" "$ai_mode" || return 1
  done
}

stop_bot_instance() {
  local bot_id="$1"
  local session="ro-$bot_id"
  if ! screen_is_running "$bot_id"; then
    echo "[OK] $bot_id 已关闭。"
    return 0
  fi

  echo "[关闭] OpenKore $bot_id"
  /usr/bin/screen -S "$session" -p 0 -X stuff $'quit\r' >/dev/null 2>&1 || true
  local i
  for i in {1..15}; do
    screen_is_running "$bot_id" || break
    sleep 1
  done
  /usr/bin/screen -S "$session" -X quit >/dev/null 2>&1 || true
  echo "[OK] $bot_id 已关闭。"
}

stop_bots() {
  local bot_id
  for bot_id in "${BOT_IDS[@]}"; do
    stop_bot_instance "$bot_id"
  done
}

class_name() {
  case "${1:-}" in
    0)  echo "Novice" ;;
    1)  echo "Swordman" ;;
    2)  echo "Mage" ;;
    3)  echo "Archer" ;;
    4)  echo "Acolyte" ;;
    5)  echo "Merchant" ;;
    6)  echo "Thief" ;;
    7)  echo "Knight" ;;
    8)  echo "Priest" ;;
    9)  echo "Wizard" ;;
    10) echo "Blacksmith" ;;
    11) echo "Hunter" ;;
    12) echo "Assassin" ;;
    *)  echo "Class $1" ;;
  esac
}

bot_status() {
  echo "OpenKore 机器人服务"
  local bot_id
  for bot_id in "${BOT_IDS[@]}"; do
    if screen_is_running "$bot_id"; then
      echo "  $bot_id: 运行中（screen: ro-$bot_id）"
    else
      echo "  $bot_id: 已关闭"
    fi
  done
}

bot_info() {
  if ! db_ready; then
    echo "  角色信息: 数据库未运行，暂无法读取"
    return 0
  fi

  local sql out
  sql='SELECT l.userid, c.name, c.base_level, c.job_level, c.class, c.zeny,'
  sql+=' c.hp, c.max_hp, c.sp, c.max_sp, c.str, c.agi, c.vit, c.`int`, c.dex, c.luk,'
  sql+=' c.last_map, c.last_x, c.last_y, c.online'
  sql+=' FROM rathena.login l JOIN rathena.`char` c ON l.account_id = c.account_id'
  sql+=' WHERE l.userid LIKE "'"$BOT_ACCOUNT_PREFIX"'"'
  sql+=' ORDER BY l.account_id ASC;'

  out=$("$MYSQL_BIN" --no-defaults --socket="$DB_SOCKET" -uroot -N -e "$sql" 2>/dev/null)

  if [[ -z "$out" ]]; then
    echo "  角色信息: 未查询到机器人角色"
    return 0
  fi

  echo "  角色信息:"
  while IFS=$'\t' read -r user name base job cls zeny hp maxhp sp maxsp str agi vit intl dex luk map x y online; do
    local cls_name="" online_str=""
    cls_name=$(class_name "$cls")
    if [[ "$online" == "1" ]]; then
      online_str="在线"
    else
      online_str="离线"
    fi
    echo "    ───────────────────────────────"
    echo "    角色: $name（账号 $user）"
    echo "      职业: $cls_name (class $cls)"
    echo "      等级: Base $base / Job $job    状态: $online_str"
    echo "      位置: $map ($x, $y)"
    echo "      HP: $hp/$maxhp   SP: $sp/$maxsp"
    echo "      属性: STR $str  AGI $agi  VIT $vit  INT $intl  DEX $dex  LUK $luk"
    echo "      Zeny: $zeny"
  done <<< "$out"
}

case "${1:-status}" in
  start)
    "$RO_CONTROL" start-backend || exit 1
    start_bots on
    ;;
  start-manual)
    "$RO_CONTROL" start-backend || exit 1
    start_bots manual
    ;;
  start-bot)
    start_bots on
    ;;
  start-one)
    [[ -n "${2:-}" ]] || { echo "请指定实例，例如：$SCRIPT_PATH start-one bot02"; exit 2; }
    start_bot_instance "$2" on
    ;;
  stop)
    stop_bots
    ;;
  stop-one)
    [[ -n "${2:-}" ]] || { echo "请指定实例，例如：$SCRIPT_PATH stop-one bot02"; exit 2; }
    stop_bot_instance "$2"
    ;;
  stop-all)
    stop_bots
    "$RO_CONTROL" stop-backend
    ;;
  restart)
    stop_bots
    start_bots on
    ;;
  console)
    bot_id="${2:-bot01}"
    if screen_is_running "$bot_id"; then
      exec /usr/bin/screen -r "ro-$bot_id"
    fi
    echo "$bot_id 未运行，请先执行：$SCRIPT_PATH start-one $bot_id"
    exit 1
    ;;
  status)
    "$RO_CONTROL" status
    ;;
  bot-status)
    bot_status
    ;;
  bot-info)
    bot_info
    ;;
  *)
    echo "用法：$SCRIPT_PATH {start|start-manual|start-bot|start-one ID|stop|stop-one ID|stop-all|restart|console [ID]|status|bot-status|bot-info}"
    exit 2
    ;;
esac
