# docker-restore-tool

> A small Bash-first tool that now handles both **Docker backup** and **Docker restore** with the same workflow and config style.

`docker-restore-tool` is built for operators who keep `/opt/<project>` style Docker directories in an `rclone` remote and want a repeatable way to:

- create compressed backups,
- upload them to remote storage,
- clean up old archives,
- restore them onto another host,
- verify which restored projects are immediately startable.

The tool remains **restore-compatible by default** while adding a new `backup` subcommand.

---

## Highlights

- **One tool for backup + restore**
- **Bash-first and easy to audit**
- **Works with any `rclone` remote**
- **Dry-run support**
- **Optional Telegram notifications**
- **Optional `--start-services` for restore**
- **Backup project list is configurable**
- **Restore auto-detects top-level projects from the archive by default**

---

## Quick Start

```bash
git clone https://github.com/lbjxr/docker-restore-tool.git
cd docker-restore-tool
chmod +x docker_restore.sh
cp .env.example .env
```

Edit `.env`, then test safely:

```bash
bash docker_restore.sh backup --config .env --dry-run
bash docker_restore.sh restore --config .env --dry-run
```

---

## Default Runtime Assumptions

Current defaults are aligned with the FOSSVPS deployment:

```bash
REMOTE_NAME=infinicloud
REMOTE_DIR=Backup/FOSSVPS/Docker
RESTORE_ROOT=/opt
BACKUP_SOURCE_ROOT=/opt
BACKUP_PROJECTS=NginxProxyManager,Resin,NewsFocus
BACKUP_RETENTION=7d
```

You can override all of these in `.env` or via CLI flags.

---

## Usage

### Restore mode

Default behavior is still restore-compatible:

```bash
bash docker_restore.sh [backup-file] [options]
bash docker_restore.sh restore [backup-file] [options]
```

Examples:

```bash
bash docker_restore.sh --config .env --yes
bash docker_restore.sh DockerBackup_2026-04-29_073625.tar.gz --config .env --yes
bash docker_restore.sh restore --config .env --dry-run
bash docker_restore.sh restore --config .env --yes --start-services
```

### Backup mode

```bash
bash docker_restore.sh backup [options]
```

Examples:

```bash
bash docker_restore.sh backup --config .env
bash docker_restore.sh backup --config .env --dry-run
bash docker_restore.sh backup --backup-projects NginxProxyManager,Resin,NewsFocus
bash docker_restore.sh backup --retention 7d
bash docker_restore.sh backup --backup-excludes "*/node_modules/*,*/tmp/*"
```

---

## Important Options

### Shared

- `-c, --config <file>` — load environment variables from config file
- `--remote <name>` — rclone remote name
- `--remote-dir <path>` — remote backup directory
- `--temp-dir <path>` — working directory
- `--log-file <path>` — log file path
- `--dry-run` — preview actions only
- `--no-telegram` — suppress Telegram notifications

### Restore-specific

- `--restore-root <path>` — restore destination root
- `--projects <csv>` — explicit verification project list
- `--start-services` — run `docker compose up -d` where possible
- `-y, --yes` — skip confirmation

### Backup-specific

- `--backup-projects <csv>` — project list to package
- `--backup-root <path>` — source root containing those projects
- `--backup-excludes <csv>` — extra tar exclude patterns appended to built-in defaults
- `--retention <age>` — remote cleanup threshold for `rclone delete --min-age`
- `--required-space-kb <n>` — minimum free space required before packaging

---

## Configuration

Example `.env`:

```bash
REMOTE_NAME=infinicloud
REMOTE_DIR=Backup/FOSSVPS/Docker
RESTORE_ROOT=/opt
TEMP_DIR=/tmp/docker_restore_work
LOG_FILE=/tmp/docker_restore.log

BACKUP_SOURCE_ROOT=/opt
BACKUP_PROJECTS=NginxProxyManager,Resin,NewsFocus
BACKUP_RETENTION=7d
BACKUP_REQUIRED_SPACE_KB=1048576
SERVER_NAME=

TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

### Notes

- Telegram token / chat ID must come from `.env` or environment variables.
- The tool no longer depends on hardcoded Telegram secrets in the script body.
- `pigz` is optional. If missing, the tool falls back to normal `gzip` behavior.
- Backup only includes directories that actually exist.
- For machine-specific backups, prefer setting both `BACKUP_PROJECTS` and `BACKUP_PROJECTS_CSV` in `.env` so the effective project list is explicit after config load.
- If you must preserve a handful of important standalone files, gather copied file contents into a small directory such as `/opt/docker-restore-tool/extra-core/` and include that directory in backup projects.

---

## Backup Flow

1. Check required tools
2. Confirm rclone remote exists
3. Check free space
4. Filter configured projects by existence under `BACKUP_SOURCE_ROOT`
5. Create `DockerBackup_YYYY-MM-DD_HHMMSS.tar.gz`
6. Verify archive integrity
7. Upload to `${REMOTE_NAME}:${REMOTE_DIR}`
8. Delete remote files older than `BACKUP_RETENTION`
9. Optionally send Telegram summary

---

## Restore Flow

1. Check required tools
2. Confirm rclone remote exists
3. List remote archives
4. Select latest or requested archive
5. Download to temp dir
6. Preview archive contents
7. Auto-detect projects from archive, unless `--projects` is given
8. Extract into staging dir
9. Copy restored files into `RESTORE_ROOT`
10. Classify projects as:
   - restored and startable
   - restored but no compose file
   - missing
11. Optionally start services
12. Optionally send Telegram summary

---

## Safety Notes

- Always run `--dry-run` first.
- Restore may overwrite files under the target root.
- `--start-services` may immediately start restored workloads.
- Remote cleanup uses `rclone delete --min-age`; keep the backup directory dedicated to backup archives.
- Local one-off backup snapshots or before-change copies should go under `backups/` and stay out of git.
- Do not commit real `.env` secrets.

---

## Example: compact OpenClaw core backup

If a host contains a large OpenClaw runtime tree, avoid backing up the entire runtime directory blindly. A safer pattern is:

- include only small core directories such as `identity`, `devices`, `config.d`, `credentials`, `cron`, `workspace/docs`, `workspace/scripts`, `workspace/memory`, `workspace/tasks`
- exclude runtime-heavy directories such as media, reports, embeddings, vendor, tmp, logs, and cached agent workspaces
- copy must-keep standalone files (for example `AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, `MEMORY.md`, `HEARTBEAT.md`, `IDENTITY.md`, `openclaw.json`) into a small helper directory like `/opt/docker-restore-tool/extra-core/`, then back up that directory

This keeps archives focused on restorable operator context instead of noisy runtime data.

## Suggested Cron Example

Run backup daily at 03:00:

```bash
0 3 * * * /usr/bin/bash /opt/docker-restore-tool/docker_restore.sh backup --config /opt/docker-restore-tool/.env >> /var/log/docker_backup_cron.log 2>&1
```

---

## Chinese Documentation

See: [README.zh-CN.md](./README.zh-CN.md)
