#!/usr/bin/env bash

# Docker Restore Tool
# Restore archived Docker project directories from an rclone remote.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_PROJECTS=(
  "NginxProxyManager"
  "HexoXR"
  "Qexo"
  "sunpanel"
  "openlist"
  "komari"
)

REMOTE_NAME="${REMOTE_NAME:-infini}"
REMOTE_DIR="${REMOTE_DIR:-Backup/RN/Docker}"
RESTORE_ROOT="${RESTORE_ROOT:-/opt}"
TEMP_DIR="${TEMP_DIR:-/tmp/docker_restore_work}"
LOG_FILE="${LOG_FILE:-/tmp/docker_restore.log}"
CONFIG_FILE="${CONFIG_FILE:-}"
BACKUP_FILE=""
YES_MODE=false
DRY_RUN=false
NO_TELEGRAM=false
PROJECTS=("${DEFAULT_PROJECTS[@]}")

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<'EOF'
Docker Restore Tool

Usage:
  bash docker_restore.sh [backup-file] [options]

Options:
  -c, --config <file>         Load environment variables from file
      --remote <name>         rclone remote name (default: infini)
      --remote-dir <path>     rclone remote directory (default: Backup/RN/Docker)
      --restore-root <path>   Destination root for restored projects (default: /opt)
      --temp-dir <path>       Working directory for downloads/extraction
      --log-file <path>       Log file path
      --projects <csv>        Comma-separated project names to verify
  -y, --yes                   Skip interactive confirmation
      --dry-run               Show actions without downloading/extracting files
      --no-telegram           Disable Telegram notification even if env vars are set
  -h, --help                  Show this help

Examples:
  bash docker_restore.sh
  bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
  bash docker_restore.sh --remote infini --remote-dir Backup/RN/Docker --dry-run
  bash docker_restore.sh --config .env --projects NginxProxyManager,openlist,komari
EOF
}

log_raw() {
  local level="$1"
  shift
  local ts
  ts="$(date +'%Y-%m-%d %H:%M:%S')"
  mkdir -p "$(dirname -- "$LOG_FILE")"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >>"$LOG_FILE"
}

log_info() {
  printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"
  log_raw INFO "$*"
}

log_success() {
  printf '%b[SUCCESS]%b %s\n' "$GREEN" "$NC" "$*"
  log_raw SUCCESS "$*"
}

log_warning() {
  printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$*"
  log_raw WARNING "$*"
}

log_error() {
  printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
  log_raw ERROR "$*"
}

run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

load_config_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    log_error "配置文件不存在: $file"
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  . "$file"
  set +a
}

parse_projects_csv() {
  local csv="$1"
  PROJECTS=()
  IFS=',' read -r -a _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="${item#${item%%[![:space:]]*}}"
    item="${item%${item##*[![:space:]]}}"
    [ -n "$item" ] && PROJECTS+=("$item")
  done
}

send_telegram() {
  local message="$1"
  local full_message
  full_message="🖥 <b>$(hostname)</b> - Docker Restore%0A%0A${message}"

  if [ "$NO_TELEGRAM" = true ]; then
    return 0
  fi

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_info "[dry-run] Telegram notification skipped: $message"
      return 0
    fi
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${full_message}" \
      -d "parse_mode=HTML" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  if [ -d "$TEMP_DIR" ]; then
    log_info "Cleaning temp directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}

error_exit() {
  local exit_code=$?
  log_error "Restore job failed (exit=$exit_code)"
  send_telegram "❌ <b>Docker restore failed</b>%0ACheck log: ${LOG_FILE}"
  cleanup
  exit "$exit_code"
}

trap error_exit ERR
trap cleanup EXIT

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --remote)
        REMOTE_NAME="$2"
        shift 2
        ;;
      --remote-dir)
        REMOTE_DIR="$2"
        shift 2
        ;;
      --restore-root)
        RESTORE_ROOT="$2"
        shift 2
        ;;
      --temp-dir)
        TEMP_DIR="$2"
        shift 2
        ;;
      --log-file)
        LOG_FILE="$2"
        shift 2
        ;;
      --projects)
        parse_projects_csv "$2"
        shift 2
        ;;
      -y|--yes)
        YES_MODE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --no-telegram)
        NO_TELEGRAM=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [ -z "$BACKUP_FILE" ]; then
          BACKUP_FILE="$1"
        else
          log_error "Unexpected extra argument: $1"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done
}

check_dependencies() {
  log_info "Checking dependencies..."

  local missing=()
  local optional_missing=()

  for cmd in rclone tar awk grep sed cut du; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  command -v pigz >/dev/null 2>&1 || optional_missing+=("pigz")
  command -v column >/dev/null 2>&1 || optional_missing+=("column")

  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 1
  fi

  if [ "${#optional_missing[@]}" -gt 0 ]; then
    log_warning "Optional tools not found: ${optional_missing[*]}"
  fi

  log_success "Dependency check passed"
}

check_rclone_config() {
  log_info "Checking rclone remote: ${REMOTE_NAME}"
  if ! rclone listremotes | grep -Fxq "${REMOTE_NAME}:"; then
    log_error "rclone remote not found: ${REMOTE_NAME}"
    exit 1
  fi
  log_success "rclone remote exists"
}

list_backups_raw() {
  rclone ls "${REMOTE_NAME}:${REMOTE_DIR}" | grep 'DockerBackup_' || true
}

list_backups() {
  log_info "Fetching backups from ${REMOTE_NAME}:${REMOTE_DIR}"
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Available backups"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local results
  results="$(list_backups_raw)"
  if [ -z "$results" ]; then
    log_error "No backup files found under ${REMOTE_NAME}:${REMOTE_DIR}"
    exit 1
  fi

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$results" | awk '{size=$1; $1=""; sub(/^ /, ""); printf "%d. %s (%.2f MB)\n", NR, $0, size/1024/1024 }' | column -t
  else
    printf '%s\n' "$results" | awk '{size=$1; $1=""; sub(/^ /, ""); printf "%d. %s (%.2f MB)\n", NR, $0, size/1024/1024 }'
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
}

select_backup() {
  local selected="${BACKUP_FILE}"
  local results
  results="$(list_backups_raw)"

  if [ -z "$results" ]; then
    log_error "No backup files found"
    exit 1
  fi

  if [ -z "$selected" ]; then
    selected="$(printf '%s\n' "$results" | sort -k2 -r | head -1 | awk '{$1=""; sub(/^ /, ""); print $0}')"
    [ -n "$selected" ] || { log_error "Failed to auto-select latest backup"; exit 1; }
    log_info "Auto-selected latest backup: $selected"
  else
    if ! printf '%s\n' "$results" | awk '{$1=""; sub(/^ /, ""); print $0}' | grep -Fxq "$selected"; then
      log_error "Backup file not found: $selected"
      exit 1
    fi
    log_info "Using requested backup: $selected"
  fi

  BACKUP_FILE="$selected"
}

download_backup() {
  local local_path="${TEMP_DIR}/$(basename -- "$BACKUP_FILE")"
  log_info "Preparing backup download"
  log_info "Remote: ${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_FILE}"
  log_info "Local : ${local_path}"

  mkdir -p "$TEMP_DIR"
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Skipping download"
    DOWNLOADED_BACKUP="$local_path"
    return 0
  fi

  rclone copy "${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_FILE}" "$TEMP_DIR" \
    --progress \
    --transfers 4 \
    --buffer-size 64M

  if [ ! -f "$local_path" ]; then
    log_error "Download failed: $local_path not found"
    exit 1
  fi

  local size
  size="$(du -h "$local_path" | cut -f1)"
  log_success "Download completed: $size"
  DOWNLOADED_BACKUP="$local_path"
}

confirm_restore() {
  if [ "$YES_MODE" = true ]; then
    log_info "Confirmation skipped (--yes)"
    return 0
  fi

  printf '\n'
  printf 'Restore into %s and overwrite existing files? Type yes to continue: ' "$RESTORE_ROOT"
  local confirm
  read -r confirm
  if [ "$confirm" != "yes" ]; then
    log_warning "Restore cancelled by user"
    exit 0
  fi
}

extract_backup() {
  local backup_path="$1"
  local stage_dir="${TEMP_DIR}/extracted"
  local relative_root="${RESTORE_ROOT#/}"
  local source_dir

  if [ -z "$relative_root" ]; then
    log_error "restore-root cannot be / for this script version"
    exit 1
  fi

  source_dir="${stage_dir}/${relative_root}"

  log_info "Inspecting archive contents"
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would preview archive: $backup_path"
  else
    tar -tzf "$backup_path" | head -20
    echo '...'
  fi

  confirm_restore

  mkdir -p "$stage_dir"
  mkdir -p "$RESTORE_ROOT"

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would extract archive into staging dir: $stage_dir"
    log_info "[dry-run] Would copy ${source_dir}/. -> ${RESTORE_ROOT}/"
    return 0
  fi

  log_info "Extracting archive to staging directory: $stage_dir"
  if command -v pigz >/dev/null 2>&1; then
    tar -I pigz -xvf "$backup_path" -C "$stage_dir" 2>&1 | tee -a "$LOG_FILE"
  else
    tar -xzvf "$backup_path" -C "$stage_dir" 2>&1 | tee -a "$LOG_FILE"
  fi

  if [ ! -d "$source_dir" ]; then
    log_error "Expected extracted directory not found: $source_dir"
    exit 1
  fi

  log_info "Copying restored files into ${RESTORE_ROOT}"
  cp -a "${source_dir}/." "$RESTORE_ROOT/"
  log_success "Files restored into ${RESTORE_ROOT}"
}

verify_restore() {
  log_info "Verifying restored projects under ${RESTORE_ROOT}"
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Restored projects"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local success_count=0
  local total_count="${#PROJECTS[@]}"
  local project

  if [ "$total_count" -eq 0 ]; then
    log_warning "No projects configured for verification"
    return 0
  fi

  for project in "${PROJECTS[@]}"; do
    if [ -d "${RESTORE_ROOT}/${project}" ]; then
      local size='N/A'
      if [ "$DRY_RUN" = false ]; then
        size="$(du -sh "${RESTORE_ROOT}/${project}" | cut -f1)"
      fi
      printf '✅ %s - %s\n' "$project" "$size"
      success_count=$((success_count + 1))
    else
      printf '❌ %s - not found\n' "$project"
    fi
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf 'Restore progress: %s/%s\n' "$success_count" "$total_count"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  if [ "$success_count" -eq "$total_count" ]; then
    log_success "All configured projects verified"
    return 0
  fi

  log_warning "Some configured projects were not found"
  return 1
}

show_next_steps() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Next steps"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  cat <<EOF
1. Install Docker and Compose if needed:
   curl -fsSL https://get.docker.com | bash
   apt install docker-compose-plugin -y

2. Start restored services:
$(for project in "${PROJECTS[@]}"; do printf '   cd %s/%s && docker compose up -d\n' "$RESTORE_ROOT" "$project"; done)
3. Check container status:
   docker ps -a

4. Inspect logs when needed:
   docker compose logs -f
EOF
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main() {
  parse_args "$@"

  if [ -z "$CONFIG_FILE" ] && [ -f "${SCRIPT_DIR}/config.example.env" ]; then
    :
  fi

  if [ -n "$CONFIG_FILE" ]; then
    load_config_file "$CONFIG_FILE"
    REMOTE_NAME="${REMOTE_NAME:-infini}"
    REMOTE_DIR="${REMOTE_DIR:-Backup/RN/Docker}"
    RESTORE_ROOT="${RESTORE_ROOT:-/opt}"
    TEMP_DIR="${TEMP_DIR:-/tmp/docker_restore_work}"
    LOG_FILE="${LOG_FILE:-/tmp/docker_restore.log}"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  fi

  log_info "Starting Docker restore tool"
  log_info "Remote       : ${REMOTE_NAME}:${REMOTE_DIR}"
  log_info "Restore root : ${RESTORE_ROOT}"
  log_info "Temp dir     : ${TEMP_DIR}"
  log_info "Log file     : ${LOG_FILE}"
  log_info "Projects     : ${PROJECTS[*]:-<none>}"
  [ "$DRY_RUN" = true ] && log_warning "Running in dry-run mode"

  check_dependencies
  check_rclone_config
  list_backups
  select_backup
  download_backup
  extract_backup "$DOWNLOADED_BACKUP"

  if verify_restore; then
    send_telegram "✅ <b>Docker restore succeeded</b>%0ABackup: ${BACKUP_FILE}%0ALocation: ${RESTORE_ROOT}"
  else
    send_telegram "⚠️ <b>Docker restore partially succeeded</b>%0ABackup: ${BACKUP_FILE}%0ACheck log: ${LOG_FILE}"
  fi

  show_next_steps
  log_success "Restore job completed"
}

main "$@"
