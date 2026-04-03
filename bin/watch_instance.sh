#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

usage() {
  echo "Uso: $0 <instancia>"
}

should_exclude_path() {
  local rel_path="$1"
  local ex
  if ! declare -p EXCLUDES >/dev/null 2>&1; then
    return 1
  fi
  for ex in "${EXCLUDES[@]}"; do
    [[ -n "$ex" ]] || continue
    if [[ "$rel_path" == $ex || "$rel_path" == $ex* ]]; then
      return 0
    fi
  done
  return 1
}

polling_watch() {
  local instance="$1"
  local local_dir="$2"
  local pending_file="$3"
  local excludes_file="$4"
  local snapshot_file="$5"

  local find_excludes=()
  while IFS= read -r ex; do
    [[ -n "$ex" ]] || continue
    find_excludes+=("!" "-path" "$local_dir/$ex")
    find_excludes+=("!" "-path" "$local_dir/$ex/*")
  done < "$excludes_file"

  build_snapshot() {
    find "$local_dir" -type f "${find_excludes[@]}" -printf '%P|%T@|%s\n' | sort
  }

  build_snapshot > "$snapshot_file"

  while true; do
    sleep 2
    local current_file
    current_file="$(mktemp "${snapshot_file}.XXXX")"
    build_snapshot > "$current_file"

    # Detect deletes and modifications
    while IFS='|' read -r path old_mtime old_size; do
      [[ -n "$path" ]] || continue
      local cur_line
      cur_line="$(grep -F "^$path|" "$current_file" || true)"
      if [[ -z "$cur_line" ]]; then
        printf '[%s] DELETE %s\n' "$(now_ts)" "$path" >> "$pending_file"
        continue
      fi
      local _p new_mtime new_size
      IFS='|' read -r _p new_mtime new_size <<< "$cur_line"
      if [[ "$old_mtime" != "$new_mtime" || "$old_size" != "$new_size" ]]; then
        printf '[%s] MODIFY %s\n' "$(now_ts)" "$path" >> "$pending_file"
      fi
    done < "$snapshot_file"

    # Detect creates
    while IFS='|' read -r path _mtime _size; do
      [[ -n "$path" ]] || continue
      if ! grep -Fq "^$path|" "$snapshot_file"; then
        printf '[%s] CREATE %s\n' "$(now_ts)" "$path" >> "$pending_file"
      fi
    done < "$current_file"

    mv "$current_file" "$snapshot_file"
  done
}

event_to_action() {
  local event="$1"

  if [[ "$event" == *"MOVED_FROM"* || "$event" == *"DELETE"* ]]; then
    echo "DELETE"
    return
  fi

  if [[ "$event" == *"MOVED_TO"* || "$event" == *"CREATE"* ]]; then
    echo "CREATE"
    return
  fi

  if [[ "$event" == *"MODIFY"* || "$event" == *"CLOSE_WRITE"* ]]; then
    echo "MODIFY"
    return
  fi

  echo "EVENT"
}

main() {
  ensure_base_dirs

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local instance="$1"
  load_instance_conf "$instance"

  local pid_file pending_file
  local excludes_file snapshot_file
  pid_file="$(instance_pid_file "$instance")"
  pending_file="$(instance_pending_file "$instance")"
  excludes_file="$TMP_DIR/${instance}.excludes"
  snapshot_file="$TMP_DIR/${instance}.snapshot"

  if watcher_running "$instance"; then
    err "Watcher ja esta rodando para '$instance'"
    exit 1
  fi

  touch "$pending_file"
  : > "$excludes_file"
  if declare -p EXCLUDES >/dev/null 2>&1 && [[ ${#EXCLUDES[@]} -gt 0 ]]; then
    printf '%s\n' "${EXCLUDES[@]}" > "$excludes_file"
  fi
  echo $$ > "$pid_file"

  trap "rm -f '$pid_file'" EXIT INT TERM

  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -m -r \
      -e modify -e close_write -e create -e delete -e moved_from -e moved_to \
      --format '%e|%w|%f' \
      "$LOCAL_DIR" | while IFS='|' read -r event watched_path file_name; do
        [[ -n "$file_name" ]] || continue

        local full_path rel_path action
        full_path="${watched_path}${file_name}"
        rel_path="${full_path#${LOCAL_DIR}/}"
        if should_exclude_path "$rel_path"; then
          continue
        fi
        action="$(event_to_action "$event")"

        printf '[%s] %s %s\n' "$(now_ts)" "$action" "$rel_path" >> "$pending_file"
      done
  else
    printf '[%s] WARN inotifywait nao encontrado; usando modo polling (intervalo 2s)\n' "$(now_ts)" >> "$pending_file"
    polling_watch "$instance" "$LOCAL_DIR" "$pending_file" "$excludes_file" "$snapshot_file"
  fi
}

main "$@"
