#!/usr/bin/env bash
#
# AIplane stack: backup, restore, start, stop (interactive menu or subcommands).
#
# Default compose files for backup/restore checks: COMPOSE_FILE (colon-separated), default matches
# start/stop: docker-compose.yml + docker-compose.external-nginx.yml.
#
# Usage:
#   ./stack.sh                  # interactive menu
#   ./stack.sh backup
#   ./stack.sh restore [path]   # path optional; without path, pick under <project>/backup
#   ./stack.sh start
#   ./stack.sh stop
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Compose project name (restore volumes: ${PLANE_PROJECT}_pgdata, …)
PLANE_PROJECT="${COMPOSE_PROJECT_NAME:-}"
if [ -z "$PLANE_PROJECT" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  _line="$(grep -E '^[[:space:]]*COMPOSE_PROJECT_NAME=' "$PROJECT_ROOT/.env" | tail -n1 || true)"
  if [ -n "$_line" ]; then
    PLANE_PROJECT="${_line#*=}"
    PLANE_PROJECT="${PLANE_PROJECT%%$'\r'}"
    PLANE_PROJECT="${PLANE_PROJECT#"${PLANE_PROJECT%%[![:space:]]*}"}"
    PLANE_PROJECT="${PLANE_PROJECT%"${PLANE_PROJECT##*[![:space:]]}"}"
    PLANE_PROJECT="${PLANE_PROJECT//\"/}"
    PLANE_PROJECT="${PLANE_PROJECT//\'/}"
  fi
fi
if [ -z "$PLANE_PROJECT" ]; then
  PLANE_PROJECT="$(basename "$PROJECT_ROOT")"
fi

# Docker Compose lowercases the project name for networks/volumes (e.g. dir "AIplane" → aiplane_pgdata).
PLANE_PROJECT=$(printf '%s' "$PLANE_PROJECT" | tr '[:upper:]' '[:lower:]')

COMPOSE_FILE_ARGS=()
IFS=':' read -r -a _compose_parts <<< "${COMPOSE_FILE:-docker-compose.yml:docker-compose.external-nginx.yml}"
for _cf in "${_compose_parts[@]}"; do
  [ -z "$_cf" ] && continue
  COMPOSE_FILE_ARGS+=(-f "$PROJECT_ROOT/$_cf")
done

if command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  COMPOSE_CMD="docker compose"
fi

compose_in_project() {
  (cd "$PROJECT_ROOT" && $COMPOSE_CMD "${COMPOSE_FILE_ARGS[@]}" "$@")
}

# Start/stop use the same two compose files as documented for this repo (explicit paths).
stack_start() {
  (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$PROJECT_ROOT/docker-compose.yml" -f "$PROJECT_ROOT/docker-compose.external-nginx.yml" up -d --build)
}

stack_stop() {
  (cd "$PROJECT_ROOT" && $COMPOSE_CMD -f "$PROJECT_ROOT/docker-compose.yml" -f "$PROJECT_ROOT/docker-compose.external-nginx.yml" down)
}

function print_header() {
  clear

  cat <<"EOF"
--------------------------------------------
 ____  _                          /////////
|  _ \| | __ _ _ __   ___         /////////
| |_) | |/ _` | '_ \ / _ \   /////    /////
|  __/| | (_| | | | |  __/   /////    /////
|_|   |_|\__,_|_| |_|\___|        ////
                                  ////
--------------------------------------------
Project management tool from the future
--------------------------------------------
EOF
}

function backup_container_dir() {
  local BACKUP_FOLDER=$1
  local CONTAINER_NAME=$2
  local CONTAINER_DATA_DIR=$3
  local ARCHIVE_BASENAME=$4

  echo "Backing up $CONTAINER_NAME data..."
  local CONTAINER_ID
  CONTAINER_ID="$(compose_in_project ps -q "$CONTAINER_NAME" 2>/dev/null)"
  if [ -z "$CONTAINER_ID" ]; then
    echo "Error: service '$CONTAINER_NAME' has no running container. Start the stack before backup."
    return 1
  fi

  mkdir -p "$BACKUP_FOLDER/$ARCHIVE_BASENAME"

  echo "Copying $CONTAINER_NAME data directory..."
  docker cp "$CONTAINER_ID:$CONTAINER_DATA_DIR/." "$BACKUP_FOLDER/$ARCHIVE_BASENAME/"
  local cp_status=$?
  if [ $cp_status -ne 0 ]; then
    echo "Error: Failed to copy from $CONTAINER_NAME:$CONTAINER_DATA_DIR"
    rm -rf "$BACKUP_FOLDER/$ARCHIVE_BASENAME"
    return 1
  fi

  (
    cd "$BACKUP_FOLDER" || exit 1
    tar -czf "${ARCHIVE_BASENAME}.tar.gz" "$ARCHIVE_BASENAME/"
  )
  local tar_status=$?
  if [ $tar_status -eq 0 ]; then
    rm -rf "$BACKUP_FOLDER/$ARCHIVE_BASENAME"
  else
    echo "Error: Failed to create tar archive for $ARCHIVE_BASENAME"
    rm -rf "$BACKUP_FOLDER/$ARCHIVE_BASENAME"
    return 1
  fi

  echo "Successfully backed up $ARCHIVE_BASENAME data"
}

function backupData() {
  print_header

  local _first="${COMPOSE_FILE:-docker-compose.yml:docker-compose.external-nginx.yml}"
  _first="${_first%%:*}"
  if [ ! -f "$PROJECT_ROOT/$_first" ]; then
    echo "Error: Compose file not found: $PROJECT_ROOT/$_first"
    return 1
  fi

  if [ ! -f "$PROJECT_ROOT/.env" ]; then
    echo "Warning: No .env at $PROJECT_ROOT/.env (compose may still work if you rely on defaults)."
  fi

  local datetime
  datetime=$(date +"%Y%m%d-%H%M")
  local BACKUP_PARENT="$PROJECT_ROOT/backup"
  mkdir -p "$BACKUP_PARENT"
  local BACKUP_FOLDER="$BACKUP_PARENT/$datetime"
  mkdir -p "$BACKUP_FOLDER"

  backup_container_dir "$BACKUP_FOLDER" "plane-db" "/var/lib/postgresql/data" "pgdata" || return 1
  backup_container_dir "$BACKUP_FOLDER" "plane-minio" "/export" "uploads" || return 1
  backup_container_dir "$BACKUP_FOLDER" "plane-mq" "/var/lib/rabbitmq" "rabbitmq_data" || return 1
  backup_container_dir "$BACKUP_FOLDER" "plane-redis" "/data" "redisdata" || return 1

  echo ""
  echo "Backup completed successfully. Backup files are stored in $BACKUP_FOLDER"
  echo ""
}

function restoreSingleVolume() {
  selectedVolume=$1
  backupFolder=$2
  restoreFile=$3

  docker volume rm "$selectedVolume" >/dev/null 2>&1

  if [ $? -ne 0 ]; then
    echo "Error: Failed to remove volume $selectedVolume"
    echo ""
    return 1
  fi

  docker volume create "$selectedVolume" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: Failed to create volume $selectedVolume"
    echo ""
    return 1
  fi

  docker run --rm \
    -e TAR_NAME="$restoreFile" \
    -v "$selectedVolume":"/vol" \
    -v "$backupFolder":/backup \
    busybox sh -c 'mkdir -p /restore && tar -xzf "/backup/${TAR_NAME}.tar.gz" -C /restore && mv /restore/${TAR_NAME}/* /vol'

  if [ $? -ne 0 ]; then
    echo "Error: Failed to restore volume ${selectedVolume} from ${restoreFile}.tar.gz"
    echo ""
    return 1
  fi
  echo ".....Successfully restored volume $selectedVolume from ${restoreFile}.tar.gz"
  echo ""
}

function restoreData() {
  local BACKUP_FOLDER=$1

  if command -v realpath &>/dev/null; then
    BACKUP_FOLDER=$(realpath "$BACKUP_FOLDER")
  elif command -v readlink &>/dev/null; then
    BACKUP_FOLDER=$(readlink -f "$BACKUP_FOLDER" 2>/dev/null || echo "$BACKUP_FOLDER")
  fi
  if [ ! -d "$BACKUP_FOLDER" ]; then
    echo "Error: Backup folder does not exist: $BACKUP_FOLDER"
    return 1
  fi

  local running_ids
  running_ids="$(compose_in_project ps -q --status running 2>/dev/null || true)"
  if [ -n "$running_ids" ]; then
    echo "The AIplane Docker Compose stack appears to be running (compose project: $PLANE_PROJECT)."
    echo "Stop it before restoring (e.g. ./stack.sh stop or this menu: Stop)."
    return 1
  fi

  local volume_suffix
  volume_suffix="_pgdata|_redisdata|_uploads|_rabbitmq_data"
  local volumes
  volumes=$(docker volume ls -f "name=$PLANE_PROJECT" --format "{{.Name}}" | grep -E "$volume_suffix" || true)
  if [ -z "$volumes" ]; then
    echo ".....No volumes found for compose project '$PLANE_PROJECT' (expected names like ${PLANE_PROJECT}_pgdata)."
    echo "    Adjust COMPOSE_PROJECT_NAME / COMPOSE_FILE if needed."
    return 1
  fi

  local found_any=false
  for BACKUP_FILE in "$BACKUP_FOLDER"/*.tar.gz; do
    if [ -e "$BACKUP_FILE" ]; then
      found_any=true
      local restoreFileName
      restoreFileName=$(basename "$BACKUP_FILE")
      restoreFileName="${restoreFileName%.tar.gz}"

      local restoreVolName
      restoreVolName="${PLANE_PROJECT}_${restoreFileName}"
      echo "Found $BACKUP_FILE"

      local docVol
      docVol=$(docker volume ls -f "name=$restoreVolName" --format "{{.Name}}" | grep -E "$volume_suffix" || true)

      if [ -z "$docVol" ]; then
        echo "Skipping: No volume found with name $restoreVolName"
      else
        echo ".....Restoring $docVol"
        restoreSingleVolume "$docVol" "$BACKUP_FOLDER" "$restoreFileName"
      fi
    fi
  done

  if [ "$found_any" != true ]; then
    echo "No .tar.gz files found in: $BACKUP_FOLDER"
    return 1
  fi

  echo ""
  echo "Restore completed successfully."
  echo ""
}

# Prints chosen directory path to stdout only (prompts on stderr so command substitution works).
function pick_backup_folder() {
  if [ ! -d "$PROJECT_ROOT/backup" ]; then
    echo "No backup directory at $PROJECT_ROOT/backup" >&2
    return 1
  fi
  local _backup_dirs=()
  mapfile -t _backup_dirs < <(find "$PROJECT_ROOT/backup" -mindepth 1 -maxdepth 1 -type d | sort)
  if [ ${#_backup_dirs[@]} -eq 0 ]; then
    echo "No backup snapshots found under $PROJECT_ROOT/backup" >&2
    return 1
  fi
  echo "" >&2
  echo "Backup snapshots (sorted by name):" >&2
  local i=1
  local d
  for d in "${_backup_dirs[@]}"; do
    echo "  $i) $(basename "$d")" >&2
    echo "      $d" >&2
    ((i++)) || true
  done
  echo "" >&2
  read -r -p "Enter number (1-${#_backup_dirs[@]}): " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#_backup_dirs[@]}" ]; then
    echo "Invalid selection." >&2
    return 1
  fi
  echo "${_backup_dirs[$((choice - 1))]}"
}

function run_restore_interactive() {
  print_header
  local picked
  picked="$(pick_backup_folder)" || return 1
  echo ""
  echo "Restoring from: $picked"
  echo ""
  restoreData "$picked"
}

function show_menu() {
  print_header
  echo ""
  echo "  1) Backup (volume archives under $PROJECT_ROOT/backup/<timestamp>)"
  echo "  2) Restore (choose a folder under $PROJECT_ROOT/backup)"
  echo "  3) Start stack (docker compose: docker-compose.yml + docker-compose.external-nginx.yml, up -d --build)"
  echo "  4) Stop stack  (docker compose down, same files)"
  echo "  0) Exit"
  echo ""
  read -r -p "Select action [0-4]: " action
  case "$action" in
    1)
      backupData || true
      ;;
    2)
      run_restore_interactive || true
      ;;
    3)
      echo "Starting stack..."
      stack_start
      ;;
    4)
      echo "Stopping stack..."
      stack_stop
      ;;
    0|"")
      exit 0
      ;;
    *)
      echo "Invalid selection."
      ;;
  esac
}

function print_help() {
  cat <<EOF
Usage: $0 [command]

Commands:
  (none)     Interactive menu
  backup     Create timestamped backup under $PROJECT_ROOT/backup/
  restore [path]  Restore from path, or omit path to pick a folder under backup/
  start      docker compose up -d --build (docker-compose.yml + docker-compose.external-nginx.yml)
  stop       docker compose down (same files)
  help       This help

Environment:
  COMPOSE_FILE   Colon-separated compose files for backup/restore checks (default includes both nginx override)
  COMPOSE_PROJECT_NAME  Override compose project name for volume restore
EOF
}

cmd="${1:-}"
case "$cmd" in
  ""|menu)
    show_menu
    ;;
  backup)
    backupData || exit 1
    ;;
  restore)
    if [ -n "${2:-}" ]; then
      print_header
      restoreData "$2" || exit 1
    else
      run_restore_interactive || exit 1
    fi
    ;;
  start)
    stack_start
    ;;
  stop)
    stack_stop
    ;;
  help|-h|--help)
    print_help
    ;;
  *)
    echo "Unknown command: $cmd"
    print_help
    exit 1
    ;;
esac
