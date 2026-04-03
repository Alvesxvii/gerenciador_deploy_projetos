#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

LOCK_FILE=""

cleanup_lock() {
  if [[ -n "${LOCK_FILE:-}" ]]; then
    rm -f "$LOCK_FILE"
  fi
}

usage() {
  echo "Uso: $0 <instancia> [--mode changes|all] [--delete]"
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
  if declare -p EXCLUDES >/dev/null 2>&1; then
    for ex in "${EXCLUDES[@]}"; do
      args+=("--exclude-glob" "$ex")
    done
  fi
  printf '%q ' "${args[@]}"
}

build_changes_script() {
  local pending_file="$1"
  local remote_dir="$2"
  local script_file="$3"

  declare -A latest_action=()
  local line ts action path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ts="${line%%] *}"
    ts="${ts#[}"
    action="${line#*] }"
    action="${action%% *}"
    path="${line#*] $action }"
    [[ -n "$path" ]] || continue
    case "$action" in
      CREATE|MODIFY|DELETE)
        latest_action["$path"]="$action"
        ;;
    esac
  done < "$pending_file"

  {
    echo "set ftp:ssl-force $ssl_force"
    echo "set ftp:ssl-protect-data true"
    echo "set ssl:verify-certificate $ssl_verify"
    echo "set cmd:fail-exit yes"
    echo "set xfer:clobber true"
    if [[ "$remote_dir" != "/" ]]; then
      echo "mkdir -p \"$remote_dir\""
    fi

    local rel act local_path remote_path remote_parent
    for rel in "${!latest_action[@]}"; do
      act="${latest_action[$rel]}"
      local_path="$LOCAL_DIR/$rel"
      remote_path="$remote_dir/$rel"
      remote_path="${remote_path//\/\//\/}"
      remote_parent="${remote_path%/*}"
      [[ "$remote_parent" == "$remote_path" ]] && remote_parent="$remote_dir"
      remote_parent="${remote_parent//\/\//\/}"

      case "$act" in
        CREATE|MODIFY)
          if [[ -d "$local_path" ]]; then
            echo "mkdir -p \"$remote_path\""
          elif [[ -f "$local_path" ]]; then
            echo "mkdir -p \"$remote_parent\""
            echo "put -O \"$remote_parent\" \"$local_path\""
          fi
          ;;
        DELETE)
          echo "rm -f \"$remote_path\""
          echo "rmdir \"$remote_path\""
          ;;
      esac
    done
    echo "bye"
  } > "$script_file"
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
  local mode="changes"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        shift
        [[ $# -gt 0 ]] || { err "Informe modo para --mode (changes|all)"; exit 1; }
        mode="$1"
        ;;
      --mode=*)
        mode="${1#--mode=}"
        ;;
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

  case "$mode" in
    changes|all) ;;
    *)
      err "Modo invalido: $mode (use changes ou all)"
      exit 1
      ;;
  esac

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
  LOCK_FILE="$lock_file"
  trap cleanup_lock EXIT INT TERM

  local ssl_verify ssl_force delete_option exclude_args script_file
  ssl_verify="$(bool_to_lftp "${FTP_VERIFY_CERT:-false}")"
  ssl_force="$(bool_to_lftp "${FTP_SSL:-true}")"
  script_file="$TMP_DIR/${instance}.changes.lftp"

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
    echo "[$(now_ts)] MODO_SYNC=$mode"
    echo "[$(now_ts)] DELETE_REMOTO=$delete_flag"

    if [[ "$mode" == "all" ]]; then
      # shellcheck disable=SC2086
      lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" <<LFTP_CMDS
set ftp:ssl-force $ssl_force
set ftp:ssl-protect-data true
set ssl:verify-certificate $ssl_verify
set cmd:fail-exit yes
mirror -R "$LOCAL_DIR" "$REMOTE_DIR" --verbose $delete_option $exclude_args
bye
LFTP_CMDS
    else
      if [[ ! -s "$pending_file" ]]; then
        echo "[$(now_ts)] Nenhuma alteracao pendente. Nada para sincronizar."
      else
        build_changes_script "$pending_file" "$REMOTE_DIR" "$script_file"
        lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" < "$script_file"
      fi
    fi

    echo "[$(now_ts)] Sync concluido com sucesso"
  } >> "$log_file" 2>&1

  : > "$pending_file"
  rm -f "$script_file"
}

main "$@"
