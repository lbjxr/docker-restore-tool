# docker-restore-tool

A Bash-first restore utility for recovering Docker project backups from an `rclone` remote onto a fresh server.

It is designed for the very practical ops workflow of:

1. storing compressed backups remotely,
2. pulling the selected archive to a temporary workspace,
3. extracting it safely into a staging directory,
4. copying the restored project tree into a target root such as `/opt`,
5. verifying that expected project directories exist.

## Features

- Works with any `rclone` remote
- Lists available backup archives from a remote directory
- Auto-selects the latest backup when no file is specified
- Supports explicit backup file selection
- Extracts into a staging directory before copying into the final restore root
- Verifies restored projects using a configurable project list
- Optional Telegram notifications
- Supports non-interactive execution with `--yes`
- Supports dry runs with `--dry-run`
- Supports runtime overrides for remote, directory, restore root, temp dir, log file, and project list
- Supports loading env-style config from a file

## Why this exists

A lot of “restore scripts” are really just one-off shell fragments glued together during an incident. This project turns that pattern into a small reusable tool that is:

- easier to review,
- easier to rerun,
- safer to publish,
- easier to adapt for another host or another backup location.

## Requirements

Required tools:

- `bash`
- `rclone`
- `tar`
- `awk`
- `grep`
- `sed`
- `cut`
- `du`

Optional but recommended:

- `pigz` — faster decompression
- `column` — nicer backup list formatting
- `curl` — required only for Telegram notification delivery

## Installation

Clone the repository:

```bash
git clone <your-repo-url>
cd docker-restore-tool
chmod +x docker_restore.sh
```

Install dependencies on Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y tar pigz bsdextrautils curl
curl https://rclone.org/install.sh | sudo bash
```

## Quick start

### 1. Configure rclone

```bash
rclone config
rclone listremotes
```

### 2. Test remote access

```bash
rclone ls infini:Backup/RN/Docker
```

### 3. Run a dry run first

```bash
bash docker_restore.sh --dry-run
```

### 4. Run an actual restore

```bash
bash docker_restore.sh --yes
```

Or specify an exact backup file:

```bash
bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
```

## Usage

```bash
bash docker_restore.sh [backup-file] [options]
```

### Options

| Option | Description |
|---|---|
| `-c, --config <file>` | Load environment variables from a config file |
| `--remote <name>` | rclone remote name |
| `--remote-dir <path>` | rclone remote directory |
| `--restore-root <path>` | Final destination root |
| `--temp-dir <path>` | Temporary working directory |
| `--log-file <path>` | Log file path |
| `--projects <csv>` | Comma-separated project names for verification |
| `-y, --yes` | Skip interactive confirmation |
| `--dry-run` | Print intended actions without changing files |
| `--no-telegram` | Disable Telegram notifications |
| `-h, --help` | Show help |

## Configuration

You can either pass flags directly or load settings from a file.

Example config file: [`config.example.env`](./config.example.env)

```bash
cp config.example.env .env
```

Then edit it and run:

```bash
bash docker_restore.sh --config .env --yes
```

### Supported config variables

```bash
REMOTE_NAME=infini
REMOTE_DIR=Backup/RN/Docker
RESTORE_ROOT=/opt
TEMP_DIR=/tmp/docker_restore_work
LOG_FILE=/tmp/docker_restore.log
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

## Examples

Restore latest archive from the default remote:

```bash
bash docker_restore.sh --yes
```

Restore a specific archive:

```bash
bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
```

Use a custom remote and target directory:

```bash
bash docker_restore.sh \
  --remote myremote \
  --remote-dir backups/docker \
  --restore-root /srv/apps \
  --yes
```

Verify only selected projects:

```bash
bash docker_restore.sh --projects NginxProxyManager,openlist,komari --yes
```

Preview everything without changing the filesystem:

```bash
bash docker_restore.sh --dry-run
```

Disable notifications even if env vars are present:

```bash
bash docker_restore.sh --yes --no-telegram
```

## How it works

1. Validate required tools
2. Validate that the `rclone` remote exists
3. List available backup files in the remote directory
4. Choose the latest archive or use the requested filename
5. Download the archive into a temp directory
6. Preview archive contents
7. Extract into a staging directory under the temp directory
8. Copy the staged restore root into the final destination
9. Verify expected project directories
10. Print follow-up operational steps

## Safety notes

This tool is intentionally powerful. That means it can also be dangerous.

### What to watch out for

- It restores real files into a destination such as `/opt`
- Existing files may be overwritten
- It assumes the archive structure matches your chosen `--restore-root`
- Telegram notifications send execution results to an external service
- The script trusts the operator’s `rclone` configuration and remote contents

### Recommended practice

- Test with `--dry-run` first
- Use a disposable VM before production use
- Snapshot the host before a real restore
- Review the archive layout with `tar -tzf`
- Do not commit live tokens, chat IDs, remote credentials, or internal hostnames

## Limitations

- The verification step only checks whether expected directories exist
- It does not validate application health after container startup
- It does not currently verify checksums or signatures
- It assumes tar.gz archives
- It is designed for directory restores, not database-aware logical restores

## Roadmap

Potential next improvements:

- checksum validation (`sha256`)
- archive manifest support
- project auto-discovery instead of a static project list
- rollback/backup of existing destination directories before overwrite
- structured logging
- health-check hooks after restore
- optional rsync-based copy stage
- CI checks (`shellcheck`, `shfmt`)

## Publishing checklist

Before pushing this repository to GitHub, confirm that:

- [x] no real Telegram token is hardcoded
- [x] no real Telegram chat ID is hardcoded
- [x] no private remote credentials are stored in the repo
- [x] no internal hostnames or private IPs are embedded
- [x] README documents the restore risks clearly

## Project structure

```text
.
├── .gitignore
├── LICENSE
├── README.md
├── config.example.env
└── docker_restore.sh
```

## License

MIT
