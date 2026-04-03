#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"
STATE_DIR="$PROJECT_ROOT/state"
LOGS_DIR="$PROJECT_ROOT/logs"
TMP_DIR="$PROJECT_ROOT/tmp"
CURRENT_INSTANCE_FILE="$STATE_DIR/current_instance"

ensure_base_dirs() {
  mkdir -p "$INSTANCES_DIR" "$STATE_DIR" "$LOGS_DIR" "$TMP_DIR"
}

err() {
  echo "Erro: $*" >&2
}

now_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

instance_conf_path() {
  local instance="$1"
  echo "$INSTANCES_DIR/${instance}.conf"
}

instance_pending_file() {
  local instance="$1"
  echo "$STATE_DIR/${instance}.pending"
}

instance_pid_file() {
  local instance="$1"
  echo "$STATE_DIR/${instance}.watch.pid"
}

instance_sync_lock_file() {
  local instance="$1"
  echo "$STATE_DIR/${instance}.sync.lock"
}

instance_sync_log_file() {
  local instance="$1"
  echo "$LOGS_DIR/${instance}.sync.log"
}

list_instances() {
  shopt -s nullglob
  local f
  for f in "$INSTANCES_DIR"/*.conf; do
    basename "$f" .conf
  done
}

instance_exists() {
  local instance="$1"
  [[ -f "$(instance_conf_path "$instance")" ]]
}

set_current_instance() {
  local instance="$1"
  echo "$instance" > "$CURRENT_INSTANCE_FILE"
}

get_current_instance() {
  if [[ -f "$CURRENT_INSTANCE_FILE" ]]; then
    local cur
    cur="$(tr -d '[:space:]' < "$CURRENT_INSTANCE_FILE")"
    if [[ -n "$cur" ]]; then
      echo "$cur"
      return 0
    fi
  fi
  return 1
}

resolve_instance() {
  local provided="${1:-}"
  if [[ -n "$provided" ]]; then
    echo "$provided"
    return 0
  fi
  get_current_instance
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

watcher_running() {
  local instance="$1"
  local pid_file
  pid_file="$(instance_pid_file "$instance")"

  [[ -f "$pid_file" ]] || return 1

  local pid
  pid="$(tr -d '[:space:]' < "$pid_file")"
  is_pid_running "$pid"
}

load_instance_conf() {
  local instance="$1"
  local conf
  conf="$(instance_conf_path "$instance")"

  if [[ ! -f "$conf" ]]; then
    err "Instancia '$instance' nao encontrada em $INSTANCES_DIR"
    return 1
  fi

  # shellcheck disable=SC1090
  source "$conf"

  : "${INSTANCE_NAME:?INSTANCE_NAME ausente no arquivo de configuracao}"
  : "${LOCAL_DIR:?LOCAL_DIR ausente no arquivo de configuracao}"
  : "${REMOTE_DIR:?REMOTE_DIR ausente no arquivo de configuracao}"
  : "${FTP_HOST:?FTP_HOST ausente no arquivo de configuracao}"
  : "${FTP_USER:?FTP_USER ausente no arquivo de configuracao}"
  : "${FTP_PASS:?FTP_PASS ausente no arquivo de configuracao}"

  if [[ ! -d "$LOCAL_DIR" ]]; then
    err "Diretorio LOCAL_DIR nao existe: $LOCAL_DIR"
    return 1
  fi
}
