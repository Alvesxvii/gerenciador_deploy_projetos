#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Uso: $0 <instancia> [--delete]"
}

bool_to_lftp() {
  local val="${1:-false}"
  case "${val,,}" in
    true|1|yes|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

build_exclude_args() {
  local args=()
  local ex
  for ex in "${EXCLUDES[@]:-}"; do
    args+=("--exclude-glob" "$ex")
  done
  printf '%q ' "${args[@]}"
}

main() {
  ensure_base_dirs

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local instance="$1"
  shift || true

  local delete_flag="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete)
        delete_flag="true"
        ;;
      *)
        err "Flag desconhecida: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  load_instance_conf "$instance"

  if ! command -v lftp >/dev/null 2>&1; then
    err "lftp nao encontrado. Instale lftp."
    exit 1
  fi

  local lock_file log_file pending_file
  lock_file="$(instance_sync_lock_file "$instance")"
  log_file="$(instance_sync_log_file "$instance")"
  pending_file="$(instance_pending_file "$instance")"

  if [[ -f "$lock_file" ]]; then
    local existing_pid
    existing_pid="$(tr -d '[:space:]' < "$lock_file" || true)"
    if is_pid_running "$existing_pid"; then
      err "Sync ja em execucao para '$instance' (PID $existing_pid)"
      exit 1
    fi
    rm -f "$lock_file"
  fi

  echo $$ > "$lock_file"
  trap 'rm -f "$lock_file"' EXIT INT TERM

  local ssl_verify ssl_force delete_option exclude_args
  ssl_verify="$(bool_to_lftp "${FTP_VERIFY_CERT:-false}")"
  ssl_force="$(bool_to_lftp "${FTP_SSL:-true}")"

  if [[ "$delete_flag" == "true" ]]; then
    delete_option="--delete"
  else
    delete_option=""
  fi

  exclude_args="$(build_exclude_args)"

  {
    echo "[$(now_ts)] Iniciando sync da instancia '$instance'"
    echo "[$(now_ts)] Aviso: proteja credenciais. Recomenda-se chmod 600 em instances/*.conf"
    echo "[$(now_ts)] LOCAL_DIR=$LOCAL_DIR"
    echo "[$(now_ts)] REMOTE_DIR=$REMOTE_DIR"
    echo "[$(now_ts)] DELETE_REMOTO=$delete_flag"

    # shellcheck disable=SC2086
    lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" <<LFTP_CMDS
set ftp:ssl-force $ssl_force
set ftp:ssl-protect-data true
set ssl:verify-certificate $ssl_verify
set cmd:fail-exit yes
mirror -R "$LOCAL_DIR" "$REMOTE_DIR" --verbose $delete_option $exclude_args
bye
LFTP_CMDS

    echo "[$(now_ts)] Sync concluido com sucesso"
  } >> "$log_file" 2>&1

  : > "$pending_file"
}

main "$@"
