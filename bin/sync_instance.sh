#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

LOCK_FILE=""
LOG_ENABLED="false"
SYNC_LOG_FILE=""

cleanup_lock() {
  if [[ -n "${LOCK_FILE:-}" ]]; then
    rm -f "$LOCK_FILE"
  fi
}

usage() {
  echo "Uso: $0 <instancia> [--mode changes|all] [--delete] [--verify] [--verify-pending]"
}

is_true() {
  local val="${1:-false}"
  case "${val,,}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

emit_line() {
  local line="$1"
  echo "$line"
  if [[ "$LOG_ENABLED" == "true" && -n "$SYNC_LOG_FILE" ]]; then
    echo "$line" >> "$SYNC_LOG_FILE"
  fi
}

append_file_to_log() {
  local file="$1"
  if [[ "$LOG_ENABLED" == "true" && -n "$SYNC_LOG_FILE" && -f "$file" ]]; then
    cat "$file" >> "$SYNC_LOG_FILE"
  fi
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
  local planned_summary_file="$4"

  declare -A latest_action=()
  local line action path
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
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
    : > "$planned_summary_file"
    for rel in "${!latest_action[@]}"; do
      act="${latest_action[$rel]}"
      local_path="$LOCAL_DIR/$rel"
      remote_path="$remote_dir/$rel"
      remote_path="${remote_path//\/\//\/}"

      remote_parent="${remote_path%/*}"
      [[ "$remote_parent" == "$remote_path" ]] && remote_parent="$remote_dir"
      remote_parent="${remote_parent//\/\//\/}"
      [[ -n "$remote_parent" ]] || remote_parent="$remote_dir"
      [[ -n "$remote_parent" ]] || remote_parent="/"

      case "$act" in
        CREATE|MODIFY)
          if [[ -d "$local_path" ]]; then
            if [[ "$remote_path" != "/" ]]; then
              echo "mkdir -p \"$remote_path\""
            fi
            echo "MKDIR $remote_path" >> "$planned_summary_file"
          elif [[ -f "$local_path" ]]; then
            if [[ "$remote_parent" != "/" ]]; then
              echo "mkdir -p \"$remote_parent\""
            fi
            echo "put -O \"$remote_parent\" \"$local_path\""
            echo "UPLOAD $remote_path" >> "$planned_summary_file"
          fi
          ;;
        DELETE)
          echo "rm -r -f \"$remote_path\""
          echo "DELETE $remote_path" >> "$planned_summary_file"
          ;;
      esac
    done
    echo "bye"
  } > "$script_file"
}

generate_summary() {
  local lftp_output_file="$1"
  local summary_file="$2"
  local raw_line file_path

  : > "$summary_file"

  while IFS= read -r raw_line; do
    case "$raw_line" in
      "Transferindo arquivo "*)
        file_path="${raw_line#Transferindo arquivo \`}"
        file_path="${file_path%\'}"
        echo "UPLOAD $file_path" >> "$summary_file"
        ;;
      "Removendo arquivo antigo "*)
        file_path="${raw_line#Removendo arquivo antigo \`}"
        file_path="${file_path%\'}"
        echo "DELETE $file_path" >> "$summary_file"
        ;;
    esac
  done < "$lftp_output_file"
}

remote_exists() {
  local path="$1"
  lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" >/dev/null 2>&1 <<LFTP_CMDS
set ftp:ssl-force $ssl_force
set ftp:ssl-protect-data true
set ssl:verify-certificate $ssl_verify
set cmd:fail-exit yes
cls -d "$path"
bye
LFTP_CMDS
}

run_verify() {
  local summary_file="$1"
  local has_verify_fail="false"
  local row op target

  [[ -s "$summary_file" ]] || return 0

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    op="${row%% *}"
    target="${row#* }"
    case "$op" in
      UPLOAD|MKDIR)
        if remote_exists "$target"; then
          emit_line "VERIFY_OK $target"
        else
          emit_line "VERIFY_FAIL $target"
          has_verify_fail="true"
        fi
        ;;
      DELETE)
        if remote_exists "$target"; then
          emit_line "VERIFY_FAIL $target (ainda existe)"
          has_verify_fail="true"
        else
          emit_line "VERIFY_OK $target (removido)"
        fi
        ;;
    esac
  done < "$summary_file"

  if [[ "$has_verify_fail" == "true" ]]; then
    return 1
  fi
  return 0
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
  local verify_flag="false"
  local verify_pending_flag="false"
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
      --verify)
        verify_flag="true"
        ;;
      --verify-pending)
        verify_pending_flag="true"
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
  local ssl_verify ssl_force delete_option exclude_args script_file lftp_output_file summary_file planned_summary_file

  lock_file="$(instance_sync_lock_file "$instance")"
  log_file="$(instance_sync_log_file "$instance")"
  pending_file="$(instance_pending_file "$instance")"
  ssl_verify="$(bool_to_lftp "${FTP_VERIFY_CERT:-false}")"
  ssl_force="$(bool_to_lftp "${FTP_SSL:-true}")"
  script_file="$TMP_DIR/${instance}.changes.lftp"
  lftp_output_file="$TMP_DIR/${instance}.sync.lftp.output"
  summary_file="$TMP_DIR/${instance}.sync.summary"
  planned_summary_file="$TMP_DIR/${instance}.sync.planned.summary"

  if is_true "${ENABLE_LOGS:-false}" || is_true "${SYNC_LOG_ENABLED:-false}"; then
    LOG_ENABLED="true"
    SYNC_LOG_FILE="$log_file"
    : > "$SYNC_LOG_FILE"
  fi

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

  if [[ "$delete_flag" == "true" ]]; then
    delete_option="--delete"
  else
    delete_option=""
  fi

  exclude_args="$(build_exclude_args)"

  emit_line "[$(now_ts)] Iniciando sync da instancia '$instance'"
  emit_line "[$(now_ts)] LOCAL_DIR=$LOCAL_DIR"
  emit_line "[$(now_ts)] REMOTE_DIR=$REMOTE_DIR"
  emit_line "[$(now_ts)] MODO_SYNC=$mode"
  emit_line "[$(now_ts)] DELETE_REMOTO=$delete_flag"
  emit_line "[$(now_ts)] VERIFY=$verify_flag"
  emit_line "[$(now_ts)] VERIFY_PENDING=$verify_pending_flag"

  if [[ "$verify_pending_flag" == "true" ]]; then
    if [[ "$mode" != "changes" ]]; then
      err "--verify-pending so pode ser usado com modo changes."
      exit 1
    fi
    if [[ ! -s "$pending_file" ]]; then
      emit_line "VERIFY_PENDING_SKIP sem alteracoes pendentes"
      exit 0
    fi

    build_changes_script "$pending_file" "$REMOTE_DIR" "$script_file" "$planned_summary_file"
    if run_verify "$planned_summary_file"; then
      emit_line "VERIFY_PENDING_OK"
      exit 0
    else
      emit_line "VERIFY_PENDING_FAIL"
      exit 1
    fi
  fi

  : > "$lftp_output_file"

  if [[ "$mode" == "changes" && ! -s "$pending_file" ]]; then
    emit_line "[$(now_ts)] Nenhuma alteracao pendente. Nada para sincronizar."
    emit_line "[$(now_ts)] Sync concluido com sucesso"
    emit_line "SEM_ALTERACOES_APLICADAS"
    rm -f "$script_file" "$lftp_output_file" "$summary_file"
    exit 0
  fi

  if [[ "$mode" == "all" ]]; then
    if ! lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" > "$lftp_output_file" 2>&1 <<LFTP_CMDS
set ftp:ssl-force $ssl_force
set ftp:ssl-protect-data true
set ssl:verify-certificate $ssl_verify
set cmd:fail-exit yes
mirror -R "$LOCAL_DIR" "$REMOTE_DIR" --verbose $delete_option $exclude_args
bye
LFTP_CMDS
    then
      append_file_to_log "$lftp_output_file"
      cat "$lftp_output_file" >&2
      err "Falha durante sync (modo all)."
      rm -f "$script_file" "$lftp_output_file" "$summary_file"
      exit 1
    fi
  else
    build_changes_script "$pending_file" "$REMOTE_DIR" "$script_file" "$planned_summary_file"
    if ! lftp -u "$FTP_USER,$FTP_PASS" "$FTP_HOST" > "$lftp_output_file" 2>&1 < "$script_file"; then
      append_file_to_log "$lftp_output_file"
      cat "$lftp_output_file" >&2
      err "Falha durante sync (modo changes)."
      rm -f "$script_file" "$lftp_output_file" "$summary_file" "$planned_summary_file"
      exit 1
    fi
  fi

  append_file_to_log "$lftp_output_file"
  generate_summary "$lftp_output_file" "$summary_file"

  emit_line "[$(now_ts)] Sync concluido com sucesso"
  local had_output="false"
  if [[ -s "$summary_file" ]]; then
    had_output="true"
    while IFS= read -r summary_line; do
      emit_line "APPLIED $summary_line"
    done < "$summary_file"
  fi

  if [[ "$mode" == "changes" && -s "$planned_summary_file" && "$had_output" == "false" ]]; then
    had_output="true"
    while IFS= read -r summary_line; do
      emit_line "PLANNED $summary_line"
    done < "$planned_summary_file"
  fi

  if [[ "$had_output" == "false" ]]; then
    emit_line "SEM_ALTERACOES_APLICADAS"
  fi

  if [[ "$verify_flag" == "true" ]]; then
    if [[ -s "$summary_file" ]]; then
      run_verify "$summary_file"
    elif [[ "$mode" == "changes" && -s "$planned_summary_file" ]]; then
      run_verify "$planned_summary_file"
    else
      emit_line "VERIFY_SKIP sem alteracoes para validar"
    fi
  fi

  : > "$pending_file"
  rm -f "$script_file" "$lftp_output_file" "$summary_file" "$planned_summary_file"
}

main "$@"
