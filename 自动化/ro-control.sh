#!/bin/zsh

set -u

RO_ROOT="/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local"
RATHENA_DIR="$RO_ROOT/rathena"
DB_DIR="$RO_ROOT/database"
LOG_DIR="$RO_ROOT/logs"
DB_SOCKET="$DB_DIR/mariadb.sock"
DB_PID_FILE="$DB_DIR/mariadb.pid"
DB_BIN="/opt/homebrew/opt/mariadb@11.4/bin/mariadbd"
DB_ADMIN="/opt/homebrew/opt/mariadb@11.4/bin/mariadb-admin"
PRLCTL="/usr/local/bin/prlctl"
VM_NAME="Windows 11"
OPENKORE_CTRL="/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh"

port_is_open() {
  /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

wait_for_port() {
  local port="$1"
  local label="$2"
  local i
  for i in {1..30}; do
    if port_is_open "$port"; then
      echo "[OK] $label 已就绪（端口 $port）"
      return 0
    fi
    sleep 1
  done
  echo "[失败] $label 未能在 30 秒内启动，请查看 $LOG_DIR"
  return 1
}

db_is_ready() {
  "$DB_ADMIN" --no-defaults --socket="$DB_SOCKET" ping >/dev/null 2>&1
}

start_database() {
  if db_is_ready; then
    echo "[OK] MariaDB 已运行（127.0.0.1:3307）"
    return 0
  fi

  echo "[启动] MariaDB"
  mkdir -p "$DB_DIR" "$LOG_DIR"
  /usr/bin/screen -S "ro-db" -X quit >/dev/null 2>&1 || true
  /usr/bin/screen -dmS "ro-db" /bin/zsh -lc \
    "exec '$DB_BIN' --no-defaults --datadir='$DB_DIR' --socket='$DB_SOCKET' --pid-file='$DB_PID_FILE' --log-error='$LOG_DIR/mariadb.log' --bind-address=127.0.0.1 --port=3307"

  local i
  for i in {1..30}; do
    if db_is_ready; then
      echo "[OK] MariaDB 已就绪"
      return 0
    fi
    sleep 1
  done
  echo "[失败] MariaDB 未能启动，请查看 $LOG_DIR/mariadb.log"
  return 1
}

start_server() {
  local session="$1"
  local executable="$2"
  local port="$3"
  local log_file="$4"

  if port_is_open "$port"; then
    echo "[OK] $executable 已运行（端口 $port）"
    return 0
  fi

  if pgrep -x "$executable" >/dev/null 2>&1; then
    echo "[整理] 终止未监听端口的旧 $executable 进程"
    pkill -TERM -x "$executable"
    sleep 2
  fi
  /usr/bin/screen -S "$session" -X quit >/dev/null 2>&1 || true

  echo "[启动] $executable"
  /usr/bin/screen -dmS "$session" /bin/zsh -lc \
    "cd '$RATHENA_DIR' && exec './$executable' >> '../logs/$log_file' 2>&1"
  wait_for_port "$port" "$executable"
}

start_vm() {
  local state
  state="$($PRLCTL status "$VM_NAME" 2>&1)"
  if [[ "$state" == *"running"* ]]; then
    echo "[OK] Windows 11 虚拟机已运行"
  elif [[ "$state" == *"suspended"* ]]; then
    echo "[恢复] Windows 11 虚拟机"
    "$PRLCTL" resume "$VM_NAME" || return 1
  else
    echo "[启动] Windows 11 虚拟机"
    "$PRLCTL" start "$VM_NAME" || return 1
  fi
  open -a "Parallels Desktop" >/dev/null 2>&1 || true
}

stop_server() {
  local session="$1"
  local executable="$2"
  if pgrep -x "$executable" >/dev/null 2>&1; then
    echo "[关闭] $executable"
    pkill -TERM -x "$executable"
    local i
    for i in {1..15}; do
      pgrep -x "$executable" >/dev/null 2>&1 || break
      sleep 1
    done
  else
    echo "[OK] $executable 已关闭"
  fi
  /usr/bin/screen -S "$session" -X quit >/dev/null 2>&1 || true
}

stop_database() {
  if ! db_is_ready; then
    /usr/bin/screen -S "ro-db" -X quit >/dev/null 2>&1 || true
    echo "[OK] MariaDB 已关闭"
    return 0
  fi

  echo "[关闭] MariaDB"
  if "$DB_ADMIN" --no-defaults --socket="$DB_SOCKET" shutdown >/dev/null 2>&1; then
    /usr/bin/screen -S "ro-db" -X quit >/dev/null 2>&1 || true
    echo "[OK] MariaDB 已安全关闭"
    return 0
  fi

  if [[ -f "$DB_PID_FILE" ]]; then
    local db_pid
    db_pid="$(<"$DB_PID_FILE")"
    if [[ "$db_pid" == <-> ]] && ps -p "$db_pid" -o command= | grep -F -- "--datadir=$DB_DIR" >/dev/null 2>&1; then
      kill -TERM "$db_pid"
      echo "[OK] 已向本项目 MariaDB 发送安全终止信号"
      return 0
    fi
  fi
  echo "[警告] MariaDB 未能自动关闭；为避免误伤系统的另一套 MySQL，未强制终止。"
  return 1
}

stop_vm() {
  local state
  state="$($PRLCTL status "$VM_NAME" 2>&1)"
  if [[ "$state" == *"running"* ]]; then
    if "$PRLCTL" exec "$VM_NAME" cmd.exe /d /c 'tasklist /FI "IMAGENAME eq LocalRO.exe" /NH' 2>/dev/null | grep -qi 'LocalRO.exe'; then
      echo "[暂停] 检测到游戏仍在运行。请先在 Windows 中正常退出游戏。"
      echo -n "退出后输入 y 继续暂停虚拟机，其他键取消："
      read -r answer
      [[ "$answer" == [yY] ]] || return 1
    fi
    echo "[暂停] Windows 11 虚拟机"
    "$PRLCTL" suspend "$VM_NAME" || return 1
    echo "[OK] Windows 11 已暂停，下次可快速恢复"
  else
    echo "[OK] Windows 11 当前不是运行状态"
  fi
}

show_status() {
  echo "RO 本地服状态"
  echo "----------------------------------------"
  db_is_ready && echo "MariaDB: 运行中（3307）" || echo "MariaDB: 已关闭"
  port_is_open 6900 && echo "登录服: 运行中（6900）" || echo "登录服: 已关闭"
  port_is_open 6121 && echo "角色服: 运行中（6121）" || echo "角色服: 已关闭"
  port_is_open 5121 && echo "地图服: 运行中（5121）" || echo "地图服: 已关闭"
  "$PRLCTL" status "$VM_NAME" 2>&1
  if [[ -x "/usr/local/bin/prlsrvctl" ]]; then
    local license_info trial expiration
    license_info="$(/usr/local/bin/prlsrvctl info --license 2>/dev/null)"
    trial="$(echo "$license_info" | /usr/bin/awk -F= '/is_trial=/{gsub(/\"/,"",$2); print $2}')"
    expiration="$(echo "$license_info" | /usr/bin/awk -F= '/^[[:space:]]*expiration=/{gsub(/\"/,"",$2); print $2}')"
    if [[ "$trial" == "yes" && -n "$expiration" ]]; then
      echo "Parallels: Pro 试用版，到期 $expiration"
    elif [[ -n "$license_info" ]]; then
      echo "Parallels: 已检测到正式许可证"
    fi
  fi
  echo
  "$OPENKORE_CTRL" bot-status
  "$OPENKORE_CTRL" bot-info
}

case "${1:-status}" in
  start-backend)
    echo "正在启动 RO 后端（不启动 Windows 虚拟机）……"
    start_database || exit 1
    start_server "ro-login" "login-server" 6900 "login-server.log" || exit 1
    start_server "ro-char" "char-server" 6121 "char-server.log" || exit 1
    start_server "ro-map" "map-server" 5121 "map-server.log" || exit 1
    echo
    show_status
    ;;
  start)
    echo "正在启动 RO 本地服……"
    start_database || exit 1
    start_server "ro-login" "login-server" 6900 "login-server.log" || exit 1
    start_server "ro-char" "char-server" 6121 "char-server.log" || exit 1
    start_server "ro-map" "map-server" 5121 "map-server.log" || exit 1
    start_vm || exit 1
    "$OPENKORE_CTRL" start-bot
    echo
    show_status
    echo "启动完成。进入 Windows 后双击桌面的 Local Classic RO。"
    ;;
  stop-backend)
    echo "正在关闭 RO 后端（不改变 Windows 虚拟机状态）……"
    stop_server "ro-map" "map-server"
    stop_server "ro-char" "char-server"
    stop_server "ro-login" "login-server"
    stop_database
    echo
    show_status
    ;;
  stop)
    echo "正在关闭 RO 本地服……"
    "$OPENKORE_CTRL" stop
    stop_server "ro-map" "map-server"
    stop_server "ro-char" "char-server"
    stop_server "ro-login" "login-server"
    stop_database
    stop_vm
    echo
    show_status
    ;;
  status)
    show_status
    ;;
  *)
    echo "用法：$0 {start|stop|start-backend|stop-backend|status}"
    exit 2
    ;;
esac
