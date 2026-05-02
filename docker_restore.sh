#!/usr/bin/env bash

# Docker Backup + Restore Tool
# Default behavior remains restore-compatible; backup is available via subcommand.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

MODE="restore"
REMOTE_NAME="${REMOTE_NAME:-infinicloud}"
REMOTE_DIR="${REMOTE_DIR:-Backup/FOSSVPS/Docker}"
RESTORE_ROOT="${RESTORE_ROOT:-/opt}"
TEMP_DIR="${TEMP_DIR:-/tmp/docker_restore_work}"
LOG_FILE="${LOG_FILE:-/tmp/docker_restore.log}"
CONFIG_FILE="${CONFIG_FILE:-}"
BACKUP_FILE=""
DOWNLOADED_BACKUP=""
YES_MODE=false
DRY_RUN=false
NO_TELEGRAM=false
START_SERVICES=false
PROJECTS=()
PROJECTS_SOURCE="auto-detected from archive"
SELECTED_PROJECTS_CSV=""

SERVER_NAME="${SERVER_NAME:-$(hostname)}"
BACKUP_PROJECTS_CSV="${BACKUP_PROJECTS:-NginxProxyManager,Resin,NewsFocus}"
BACKUP_SOURCE_ROOT="${BACKUP_SOURCE_ROOT:-/opt}"
BACKUP_REQUIRED_SPACE_KB="${BACKUP_REQUIRED_SPACE_KB:-1048576}"
BACKUP_RETENTION="${BACKUP_RETENTION:-7d}"
BACKUP_NAME=""
UPLOADED_BACKUP_REMOTE=""
BACKUP_INCLUDED_PROJECTS=()
BACKUP_MISSING_PROJECTS=()
BACKUP_INCLUDED_COUNT=0
BACKUP_MISSING_COUNT=0
BACKUP_SIZE_HUMAN=""
BACKUP_EXCLUDES_DEFAULT=(
  "*/Resin/data/log/*"
  "*/Resin/data/cache/*"
  "*/NginxProxyManager/data/logs/*"
  "*/NewsFocus/vps-deploy/cache/*"
  "*/.git/*"
)
BACKUP_EXCLUDES_CSV="${BACKUP_EXCLUDES:-}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

RESTORED_STARTABLE=()
RESTORED_NO_COMPOSE=()
MISSING_PROJECTS=()
STARTED_PROJECTS=()
STARTABLE_COUNT=0
RESTORED_NO_COMPOSE_COUNT=0
MISSING_COUNT=0
STARTED_COUNT=0
RESULT_KIND="失败"
RESULT_EXIT_CODE=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<'EOF'
Docker Backup + Restore Tool

Usage:
  bash docker_restore.sh [backup-file] [options]
  bash docker_restore.sh restore [backup-file] [options]
  bash docker_restore.sh backup [options]

Restore options:
  -c, --config <file>         Load environment variables from file
      --remote <name>         rclone remote name
      --remote-dir <path>     rclone remote directory
      --restore-root <path>   Destination root for restored projects (default: /opt)
      --temp-dir <path>       Working directory for downloads/extraction
      --log-file <path>       Log file path
      --projects <csv>        Comma-separated project names to verify
      --start-services        Run 'docker compose up -d' for restored projects with compose files
  -y, --yes                   Skip interactive confirmation
      --dry-run               Show actions without downloading/extracting files
      --no-telegram           Disable Telegram notification even if env vars are set
  -h, --help                  Show this help

Backup options:
  -c, --config <file>         Load environment variables from file
      --remote <name>         rclone remote name
      --remote-dir <path>     rclone remote directory
      --temp-dir <path>       Working directory for packaging/upload
      --log-file <path>       Log file path
      --backup-projects <csv> Comma-separated project names to back up
      --backup-root <path>    Root path containing projects (default: /opt)
      --retention <age>       Remote retention via rclone delete --min-age (default: 7d)
      --required-space-kb <n> Minimum free space required in temp filesystem (default: 1048576)
      --backup-excludes <csv> Extra tar exclude patterns appended to the built-in defaults
      --dry-run               Show actions without creating/uploading files
      --no-telegram           Disable Telegram notification even if env vars are set
  -h, --help                  Show this help

Examples:
  bash docker_restore.sh
  bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
  bash docker_restore.sh restore --config .env --dry-run
  bash docker_restore.sh backup --config .env
  bash docker_restore.sh backup --backup-projects NginxProxyManager,Resin,NewsFocus
  bash docker_restore.sh backup --backup-excludes "*/node_modules/*,*/tmp/*"
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

trim_spaces() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

normalize_remote_dir() {
  local value
  value="$(trim_spaces "$1")"

  while [[ "$value" == /* ]]; do
    value="${value#/}"
  done
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done
  while [[ "$value" == *//* ]]; do
    value="${value//\/\//\/}"
  done

  printf '%s' "$value"
}

join_by() {
  local delimiter="$1"
  shift || true
  local first=true
  local item

  for item in "$@"; do
    if [ "$first" = true ]; then
      printf '%s' "$item"
      first=false
    else
      printf '%s%s' "$delimiter" "$item"
    fi
  done
}

format_count_line() {
  local label="$1"
  local count="$2"
  shift 2 || true

  if [ "$count" -gt 0 ]; then
    printf '%s（%s）：%s' "$label" "$count" "$(join_by ', ' "$@")"
  else
    printf '%s（0）：无' "$label"
  fi
}

has_compose_file() {
  local project_dir="$1"
  [ -f "${project_dir}/docker-compose.yml" ] || \
  [ -f "${project_dir}/docker-compose.yaml" ] || \
  [ -f "${project_dir}/compose.yml" ] || \
  [ -f "${project_dir}/compose.yaml" ]
}

send_telegram() {
  local title="$1"
  local message="$2"
  local full_message
  full_message="🖥 <b>${SERVER_NAME}</b> - ${title}%0A%0A${message}"

  if [ "$NO_TELEGRAM" = true ]; then
    return 0
  fi

  if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    if [ "$DRY_RUN" = true ]; then
      log_info "[dry-run] Telegram notification skipped: $title"
      return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
      log_warning "curl not found; skipping Telegram notification"
      return 0
    fi
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${full_message}" \
      -d "parse_mode=HTML" >/dev/null 2>&1 || true
  fi
}

build_restore_telegram_summary() {
  local emoji="$1"
  local summary
  summary="${emoji} <b>Docker restore${RESULT_KIND}</b>%0A"
  summary+="备份名：<code>${BACKUP_FILE:-unknown}</code>%0A"
  summary+="恢复目录：<code>${RESTORE_ROOT}</code>%0A"
  summary+="恢复项目摘要：%0A"
  summary+="- $(format_count_line "已恢复且可启动" "$STARTABLE_COUNT" "${RESTORED_STARTABLE[@]}")%0A"
  summary+="- $(format_count_line "已恢复但无 compose" "$RESTORED_NO_COMPOSE_COUNT" "${RESTORED_NO_COMPOSE[@]}")%0A"
  summary+="- $(format_count_line "未恢复" "$MISSING_COUNT" "${MISSING_PROJECTS[@]}")%0A"
  summary+="可启动项目数：${STARTABLE_COUNT}%0A"
  summary+="执行结果：${RESULT_KIND}%0A"
  summary+="exit code：${RESULT_EXIT_CODE}"
  printf '%s' "$summary"
}

build_backup_telegram_summary() {
  local emoji="$1"
  local summary
  summary="${emoji} <b>Docker backup${RESULT_KIND}</b>%0A"
  summary+="备份名：<code>${BACKUP_NAME:-unknown}</code>%0A"
  summary+="远端位置：<code>${UPLOADED_BACKUP_REMOTE:-${REMOTE_NAME}:${REMOTE_DIR}}</code>%0A"
  summary+="打包项目：$(format_count_line "已纳入备份" "$BACKUP_INCLUDED_COUNT" "${BACKUP_INCLUDED_PROJECTS[@]}")%0A"
  summary+="跳过项目：$(format_count_line "缺失目录" "$BACKUP_MISSING_COUNT" "${BACKUP_MISSING_PROJECTS[@]}")%0A"
  [ -n "$BACKUP_SIZE_HUMAN" ] && summary+="文件大小：${BACKUP_SIZE_HUMAN}%0A"
  summary+="执行结果：${RESULT_KIND}%0A"
  summary+="exit code：${RESULT_EXIT_CODE}"
  printf '%s' "$summary"
}

cleanup() {
  if [ -d "$TEMP_DIR" ]; then
    log_info "Cleaning temp directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"
  fi
}

error_exit() {
  local exit_code=$?
  RESULT_KIND="失败"
  RESULT_EXIT_CODE="$exit_code"
  log_error "${MODE^} job failed (exit=$exit_code)"
  if [ "$MODE" = "backup" ]; then
    send_telegram "Docker Backup" "$(build_backup_telegram_summary '❌')"
  else
    send_telegram "Docker Restore" "$(build_restore_telegram_summary '❌')"
  fi
  cleanup
  exit "$exit_code"
}

trap error_exit ERR
trap cleanup EXIT

load_config_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    log_error "配置文件不存在: $file"
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

parse_projects_csv() {
  local csv="$1"
  local item
  PROJECTS=()
  IFS=',' read -r -a _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="$(trim_spaces "$item")"
    [ -n "$item" ] && PROJECTS+=("$item")
  done
}

parse_backup_projects_csv() {
  local csv="$1"
  local item
  BACKUP_INCLUDED_PROJECTS=()
  IFS=',' read -r -a _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="$(trim_spaces "$item")"
    [ -n "$item" ] && BACKUP_INCLUDED_PROJECTS+=("$item")
  done
}

parse_backup_excludes_csv() {
  local csv="$1"
  local item
  local parsed=()
  IFS=',' read -r -a _items <<< "$csv"
  for item in "${_items[@]}"; do
    item="$(trim_spaces "$item")"
    [ -n "$item" ] && parsed+=("$item")
  done
  printf '%s\n' "${parsed[@]}"
}

detect_mode_and_config() {
  if [ $# -gt 0 ]; then
    case "$1" in
      backup|restore)
        MODE="$1"
        shift
        ;;
      help|-h|--help)
        usage
        exit 0
        ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--config)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        CONFIG_FILE="$2"
        return 0
        ;;
    esac
    shift
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      backup|restore)
        MODE="$1"
        shift
        ;;
      -c|--config)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        CONFIG_FILE="$2"
        shift 2
        ;;
      --remote)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        REMOTE_NAME="$2"
        shift 2
        ;;
      --remote-dir)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        REMOTE_DIR="$2"
        shift 2
        ;;
      --restore-root)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        RESTORE_ROOT="$2"
        shift 2
        ;;
      --temp-dir)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        TEMP_DIR="$2"
        shift 2
        ;;
      --log-file)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        LOG_FILE="$2"
        shift 2
        ;;
      --projects)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        SELECTED_PROJECTS_CSV="$2"
        parse_projects_csv "$2"
        PROJECTS_SOURCE="user-specified (--projects)"
        shift 2
        ;;
      --backup-projects)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        BACKUP_PROJECTS_CSV="$2"
        shift 2
        ;;
      --backup-root)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        BACKUP_SOURCE_ROOT="$2"
        shift 2
        ;;
      --retention)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        BACKUP_RETENTION="$2"
        shift 2
        ;;
      --required-space-kb)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        BACKUP_REQUIRED_SPACE_KB="$2"
        shift 2
        ;;
      --backup-excludes)
        [ $# -ge 2 ] || { log_error "Missing value for $1"; exit 1; }
        BACKUP_EXCLUDES_CSV="$2"
        shift 2
        ;;
      --start-services)
        START_SERVICES=true
        shift
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
        if [ "$MODE" = "restore" ] && [ -z "$BACKUP_FILE" ]; then
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
  local cmd

  for cmd in rclone tar awk grep sed cut du cp df; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  command -v pigz >/dev/null 2>&1 || optional_missing+=("pigz")
  command -v column >/dev/null 2>&1 || optional_missing+=("column")
  command -v curl >/dev/null 2>&1 || optional_missing+=("curl")

  if [ "$MODE" = "backup" ]; then
    command -v mkdir >/dev/null 2>&1 || missing+=("mkdir")
  fi

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
  local selected="$BACKUP_FILE"
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
  local remote_path="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_FILE}"

  log_info "Preparing backup download"
  log_info "Remote: ${remote_path}"
  log_info "Local : ${local_path}"

  mkdir -p "$TEMP_DIR"
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Skipping download"
    DOWNLOADED_BACKUP="$local_path"
    return 0
  fi

  rclone copy "$remote_path" "$TEMP_DIR" \
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
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Confirmation skipped"
    return 0
  fi

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

preview_archive() {
  local backup_path="$1"

  log_info "Inspecting archive contents"
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would preview archive: $backup_path"
    return 0
  fi

  if command -v pigz >/dev/null 2>&1; then
    tar -I pigz -tf "$backup_path" | awk 'NR<=20 {print} END {if (NR>20) print "..."}'
  else
    tar -tzf "$backup_path" | awk 'NR<=20 {print} END {if (NR>20) print "..."}'
  fi
}

auto_detect_projects_from_archive() {
  local backup_path="$1"
  local relative_root="${RESTORE_ROOT#/}"
  local listing_cmd=()
  local detected=()
  local line
  local path_after_root
  local project

  if [ -z "$relative_root" ]; then
    log_error "restore-root cannot be / for auto project detection"
    exit 1
  fi

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Auto project detection needs archive contents; verification list will be determined during real run"
    PROJECTS=()
    PROJECTS_SOURCE="auto-detected from archive during real execution"
    return 0
  fi

  if command -v pigz >/dev/null 2>&1; then
    listing_cmd=(tar -I pigz -tf "$backup_path")
  else
    listing_cmd=(tar -tzf "$backup_path")
  fi

  while IFS= read -r line; do
    case "$line" in
      "$relative_root"/*)
        path_after_root="${line#${relative_root}/}"
        project="${path_after_root%%/*}"
        if [ -n "$project" ] && [ "$project" != "$path_after_root" ]; then
          detected+=("$project")
        fi
        ;;
    esac
  done < <("${listing_cmd[@]}")

  if [ "${#detected[@]}" -eq 0 ]; then
    log_warning "No top-level projects auto-detected under ${RESTORE_ROOT} from archive"
    PROJECTS=()
    PROJECTS_SOURCE="auto-detected from archive (none found)"
    return 0
  fi

  mapfile -t PROJECTS < <(printf '%s\n' "${detected[@]}" | awk '!seen[$0]++')
  PROJECTS_SOURCE="auto-detected from archive"
  log_info "Auto-detected projects: ${PROJECTS[*]}"
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

  preview_archive "$backup_path"
  if [ -z "$SELECTED_PROJECTS_CSV" ]; then
    auto_detect_projects_from_archive "$backup_path"
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

  RESTORED_STARTABLE=()
  RESTORED_NO_COMPOSE=()
  MISSING_PROJECTS=()

  local project
  local project_dir
  local size

  if [ "${#PROJECTS[@]}" -eq 0 ]; then
    log_warning "No projects configured for verification"
    STARTABLE_COUNT=0
    RESTORED_NO_COMPOSE_COUNT=0
    MISSING_COUNT=0
    echo "⚠️ 未配置校验项目"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    return 0
  fi

  for project in "${PROJECTS[@]}"; do
    project_dir="${RESTORE_ROOT}/${project}"
    if [ -d "$project_dir" ]; then
      size='N/A'
      if [ "$DRY_RUN" = false ]; then
        size="$(du -sh "$project_dir" | cut -f1)"
      fi

      if has_compose_file "$project_dir"; then
        printf '✅ %s - %s - compose found\n' "$project" "$size"
        RESTORED_STARTABLE+=("$project")
      else
        printf '🟡 %s - %s - no compose\n' "$project" "$size"
        RESTORED_NO_COMPOSE+=("$project")
      fi
    else
      printf '❌ %s - not found\n' "$project"
      MISSING_PROJECTS+=("$project")
    fi
  done

  STARTABLE_COUNT="${#RESTORED_STARTABLE[@]}"
  RESTORED_NO_COMPOSE_COUNT="${#RESTORED_NO_COMPOSE[@]}"
  MISSING_COUNT="${#MISSING_PROJECTS[@]}"

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf '已恢复且可启动: %s\n' "$STARTABLE_COUNT"
  printf '已恢复但无 compose: %s\n' "$RESTORED_NO_COMPOSE_COUNT"
  printf '未恢复: %s\n' "$MISSING_COUNT"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  if [ "$MISSING_COUNT" -eq 0 ]; then
    log_success "Verification completed without missing projects"
    return 0
  fi

  log_warning "Some projects were not restored"
  return 1
}

start_services() {
  STARTED_PROJECTS=()
  STARTED_COUNT=0

  if [ "$START_SERVICES" != true ]; then
    return 0
  fi

  if [ "$STARTABLE_COUNT" -eq 0 ]; then
    log_warning "--start-services specified, but no restored projects with compose files were found"
    return 0
  fi

  log_info "Starting restored services for projects with compose files"

  local project
  local project_dir
  for project in "${RESTORED_STARTABLE[@]}"; do
    project_dir="${RESTORE_ROOT}/${project}"
    if [ "$DRY_RUN" = true ]; then
      log_info "[dry-run] Would run: cd ${project_dir} && docker compose up -d"
      STARTED_PROJECTS+=("$project")
      continue
    fi

    (
      cd "$project_dir"
      docker compose up -d
    )
    STARTED_PROJECTS+=("$project")
    log_success "Started services: ${project}"
  done

  STARTED_COUNT="${#STARTED_PROJECTS[@]}"
}

check_backup_disk_space() {
  log_info "Checking temp filesystem free space"
  local available_space
  available_space="$(df "$TEMP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')"
  if [ -z "$available_space" ]; then
    available_space="$(df /tmp | tail -1 | awk '{print $4}')"
  fi

  if [ "$available_space" -lt "$BACKUP_REQUIRED_SPACE_KB" ]; then
    local available_gb required_gb
    available_gb="$(awk "BEGIN {printf \"%.2f\", $available_space/1024/1024}")"
    required_gb="$(awk "BEGIN {printf \"%.2f\", $BACKUP_REQUIRED_SPACE_KB/1024/1024}")"
    log_error "Insufficient disk space. Available: ${available_gb}GB, required: ${required_gb}GB"
    exit 1
  fi
  log_success "Disk space check passed"
}

build_backup_project_paths() {
  parse_backup_projects_csv "$BACKUP_PROJECTS_CSV"
  local requested=("${BACKUP_INCLUDED_PROJECTS[@]}")
  BACKUP_INCLUDED_PROJECTS=()
  BACKUP_MISSING_PROJECTS=()

  local project project_dir
  for project in "${requested[@]}"; do
    project_dir="${BACKUP_SOURCE_ROOT%/}/${project}"
    if [ -d "$project_dir" ]; then
      BACKUP_INCLUDED_PROJECTS+=("$project")
      log_info "Include backup project: $project_dir"
    else
      BACKUP_MISSING_PROJECTS+=("$project")
      log_warning "Skip missing project directory: $project_dir"
    fi
  done

  BACKUP_INCLUDED_COUNT="${#BACKUP_INCLUDED_PROJECTS[@]}"
  BACKUP_MISSING_COUNT="${#BACKUP_MISSING_PROJECTS[@]}"

  if [ "$BACKUP_INCLUDED_COUNT" -eq 0 ]; then
    log_error "No valid backup project directories found"
    exit 1
  fi
}

create_backup_archive() {
  mkdir -p "$TEMP_DIR"
  check_backup_disk_space
  build_backup_project_paths

  BACKUP_NAME="DockerBackup_$(date +'%Y-%m-%d_%H%M%S').tar.gz"
  local archive_path="${TEMP_DIR}/${BACKUP_NAME}"
  local absolute_paths=()
  local project

  for project in "${BACKUP_INCLUDED_PROJECTS[@]}"; do
    absolute_paths+=("${BACKUP_SOURCE_ROOT%/}/${project}")
  done

  log_info "Preparing backup archive: ${archive_path}"

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would archive: $(join_by ', ' "${absolute_paths[@]}")"
    BACKUP_SIZE_HUMAN="unknown (dry-run)"
    return 0
  fi

  local exclude_args=()
  local pattern
  for pattern in "${BACKUP_EXCLUDES_DEFAULT[@]}"; do
    exclude_args+=("--exclude=$pattern")
  done
  if [ -n "$BACKUP_EXCLUDES_CSV" ]; then
    while IFS= read -r pattern; do
      [ -n "$pattern" ] && exclude_args+=("--exclude=$pattern")
    done < <(parse_backup_excludes_csv "$BACKUP_EXCLUDES_CSV")
  fi

  if command -v pigz >/dev/null 2>&1; then
    log_info "Using pigz for compression"
    tar -I pigz -cf "$archive_path" "${exclude_args[@]}" "${absolute_paths[@]}" 2>>"$LOG_FILE"
  else
    log_warning "pigz not found; falling back to gzip"
    tar -czf "$archive_path" "${exclude_args[@]}" "${absolute_paths[@]}" 2>>"$LOG_FILE"
  fi

  if [ ! -f "$archive_path" ]; then
    log_error "Backup archive not created: $archive_path"
    exit 1
  fi

  if tar -tzf "$archive_path" >/dev/null 2>&1; then
    log_success "Archive integrity check passed"
  else
    log_error "Archive integrity check failed"
    exit 1
  fi

  BACKUP_SIZE_HUMAN="$(du -h "$archive_path" | cut -f1)"
  log_success "Backup archive ready: ${BACKUP_SIZE_HUMAN}"
}

upload_backup_archive() {
  local archive_path="${TEMP_DIR}/${BACKUP_NAME}"
  UPLOADED_BACKUP_REMOTE="${REMOTE_NAME}:${REMOTE_DIR}/${BACKUP_NAME}"

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would upload ${archive_path} -> ${UPLOADED_BACKUP_REMOTE}"
    return 0
  fi

  log_info "Uploading backup to ${UPLOADED_BACKUP_REMOTE}"
  rclone copy "$archive_path" "${REMOTE_NAME}:${REMOTE_DIR}" \
    --progress \
    --transfers 8 \
    --checkers 8 \
    --buffer-size 128M

  log_success "Upload completed"
}

cleanup_old_backups() {
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would delete remote backups older than ${BACKUP_RETENTION} under ${REMOTE_NAME}:${REMOTE_DIR}"
    return 0
  fi

  log_info "Cleaning remote backups older than ${BACKUP_RETENTION}"
  rclone delete "${REMOTE_NAME}:${REMOTE_DIR}" --min-age "$BACKUP_RETENTION"
  log_success "Remote retention cleanup completed"
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

2. Start restored services for projects with compose files:
EOF

  if [ "$STARTABLE_COUNT" -gt 0 ]; then
    local project
    for project in "${RESTORED_STARTABLE[@]}"; do
      printf '   cd %s/%s && docker compose up -d\n' "$RESTORE_ROOT" "$project"
    done
  else
    echo "   No restored projects with compose files were detected."
  fi

  cat <<'EOF'
3. Check container status:
   docker ps -a

4. Inspect logs when needed:
   docker compose logs -f
EOF
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

run_restore() {
  log_info "Starting Docker restore tool"
  log_info "Remote       : ${REMOTE_NAME}:${REMOTE_DIR}"
  log_info "Restore root : ${RESTORE_ROOT}"
  log_info "Temp dir     : ${TEMP_DIR}"
  log_info "Log file     : ${LOG_FILE}"
  log_info "Projects     : ${PROJECTS[*]:-<auto>}"
  log_info "Project mode : ${PROJECTS_SOURCE}"
  log_info "Start svcs   : ${START_SERVICES}"
  [ "$DRY_RUN" = true ] && log_warning "Running in dry-run mode"

  check_dependencies
  check_rclone_config
  list_backups
  select_backup
  download_backup
  extract_backup "$DOWNLOADED_BACKUP"

  if verify_restore; then
    RESULT_KIND="成功"
  else
    RESULT_KIND="部分成功"
  fi

  start_services
  RESULT_EXIT_CODE=0

  if [ "$RESULT_KIND" = "成功" ]; then
    send_telegram "Docker Restore" "$(build_restore_telegram_summary '✅')"
  else
    send_telegram "Docker Restore" "$(build_restore_telegram_summary '⚠️')"
  fi

  show_next_steps
  log_success "Restore job completed"
}

run_backup() {
  log_info "Starting Docker backup tool"
  log_info "Remote        : ${REMOTE_NAME}:${REMOTE_DIR}"
  log_info "Backup root   : ${BACKUP_SOURCE_ROOT}"
  log_info "Backup prjs   : ${BACKUP_PROJECTS_CSV}"
  log_info "Retention     : ${BACKUP_RETENTION}"
  log_info "Temp dir      : ${TEMP_DIR}"
  log_info "Log file      : ${LOG_FILE}"
  [ "$DRY_RUN" = true ] && log_warning "Running in dry-run mode"

  check_dependencies
  check_rclone_config
  create_backup_archive
  upload_backup_archive
  cleanup_old_backups

  RESULT_KIND="成功"
  RESULT_EXIT_CODE=0
  send_telegram "Docker Backup" "$(build_backup_telegram_summary '✅')"
  log_success "Backup job completed"
}

main() {
  detect_mode_and_config "$@"

  if [ -n "$CONFIG_FILE" ]; then
    load_config_file "$CONFIG_FILE"
  fi

  parse_args "$@"

  REMOTE_DIR="$(normalize_remote_dir "$REMOTE_DIR")"
  if [ -z "$REMOTE_DIR" ]; then
    log_error "remote-dir cannot be empty"
    exit 1
  fi

  case "$MODE" in
    backup)
      run_backup
      ;;
    restore)
      run_restore
      ;;
    *)
      log_error "Unsupported mode: $MODE"
      exit 1
      ;;
  esac
}

main "$@"
