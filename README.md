# docker-restore-tool

> Restore Docker project backups from an `rclone` remote to a fresh server with a Bash-first workflow.

`docker-restore-tool` is a lightweight restore utility for operators who keep compressed project backups in remote storage and want a repeatable way to recover them onto a new host.

It focuses on a pragmatic flow:

- list available backup archives,
- select the newest archive or specify one manually,
- download it via `rclone`,
- extract it into a staging directory,
- copy restored files into a target root such as `/opt`,
- verify that expected project directories exist.

---

## Features

- Supports any `rclone` remote
- Lists available backup archives from a remote directory
- Auto-selects the latest archive if no filename is provided
- Supports explicit backup selection
- Extracts into a staging directory before copying into the final destination
- Verifies restored project directories using a configurable project list
- Supports non-interactive execution with `--yes`
- Supports safe previews with `--dry-run`
- Supports env-style config files
- Optional Telegram notifications
- Small, auditable Bash codebase

---

## Quick Start

### 1. Install dependencies

```bash
sudo apt-get update
sudo apt-get install -y tar pigz bsdextrautils curl
curl https://rclone.org/install.sh | sudo bash
```

### 2. Configure `rclone`

```bash
rclone config
rclone listremotes
```

### 3. Test remote access

```bash
rclone ls infini:Backup/RN/Docker
```

### 4. Run a dry run first

```bash
bash docker_restore.sh --dry-run
```

### 5. Run a real restore

```bash
bash docker_restore.sh --yes
```

---

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

---

## Example Commands

Restore the newest archive from the default remote:

```bash
bash docker_restore.sh --yes
```

Restore a specific archive:

```bash
bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
```

Use a custom remote and destination:

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

Run with an env-style config file:

```bash
cp config.example.env .env
bash docker_restore.sh --config .env --yes
```

---

## Configuration

Example config file: [`config.example.env`](./config.example.env)

```bash
REMOTE_NAME=infini
REMOTE_DIR=Backup/RN/Docker
RESTORE_ROOT=/opt
TEMP_DIR=/tmp/docker_restore_work
LOG_FILE=/tmp/docker_restore.log
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

---

## How It Works

1. Validate required tools
2. Validate that the `rclone` remote exists
3. List available backup archives in the remote directory
4. Select the latest archive or use the provided filename
5. Download the archive into a temp directory
6. Preview archive contents
7. Extract into a staging directory
8. Copy the staged restore root into the final destination
9. Verify expected project directories
10. Print suggested post-restore actions

---

## Safety Notes

This tool is intentionally powerful. Read this before using it on production hosts.

### Risks

- It restores real files into a target directory such as `/opt`
- Existing files may be overwritten
- It assumes the archive layout matches your chosen `--restore-root`
- Telegram notifications send execution results to an external service
- It trusts the operator’s `rclone` configuration and remote contents

### Recommended Practice

- Always run `--dry-run` first
- Test on a disposable VM before production use
- Snapshot the host before a real restore
- Review the archive layout with `tar -tzf`
- Never commit live tokens, chat IDs, remote credentials, or private infrastructure details

---

## Limitations

- Verification only checks whether expected directories exist
- It does not validate application health after containers start
- It does not verify checksums or signatures yet
- It currently assumes `tar.gz` archives
- It is aimed at directory-based restores, not logical database restores

---

## Roadmap

Potential next improvements:

- SHA256 checksum validation
- archive manifest support
- project auto-discovery instead of a static project list
- automatic backup of destination directories before overwrite
- structured logging
- post-restore health checks
- optional `rsync`-based copy stage
- CI checks with `shellcheck` and `shfmt`

---

## Project Structure

```text
.
├── .gitignore
├── LICENSE
├── README.md
├── README.zh-CN.md
├── config.example.env
└── docker_restore.sh
```

---

## Chinese Documentation

For a Chinese version of this README, see:

- [README.zh-CN.md](./README.zh-CN.md)

---

## License

MIT
