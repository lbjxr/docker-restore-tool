# docker-restore-tool

> 现在这已经不是单纯“恢复工具”了，而是一套 **Docker 备份 + 恢复** 一体化的 Bash 小工具。

它适合这种场景：

- 你的 Docker 项目目录放在 `/opt/<project>` 下面；
- 你会把这些目录打成 `.tar.gz` 归档；
- 归档通过 `rclone` 上传到远程存储；
- 你希望同一套脚本既能**做备份**，也能**做恢复**；
- 而且最好还能顺手校验、发 Telegram 回执、尽量保持 Bash 风格，方便审计。

这个工具现在保持了：
- **默认行为仍兼容旧 restore 用法**；
- 同时新增了：
- `backup` 子命令。

---

## 亮点

- **一个脚本同时支持备份 + 恢复**
- **继续保持 Bash-first，便于看懂和修改**
- **支持任意 `rclone` remote**
- **支持 `--dry-run` 预演**
- **支持 Telegram 通知**
- **恢复时支持 `--start-services` 自动拉起 compose 项目**
- **备份项目列表可配置**
- **恢复时默认从归档自动探测顶层项目**

---

## 快速开始

```bash
git clone https://github.com/lbjxr/docker-restore-tool.git
cd docker-restore-tool
chmod +x docker_restore.sh
cp .env.example .env
```

改好 `.env` 后，建议先预演：

```bash
bash docker_restore.sh backup --config .env --dry-run
bash docker_restore.sh restore --config .env --dry-run
```

---

## 当前默认值

这版默认值已经按 FOSSVPS 这台机的现状对齐：

```bash
REMOTE_NAME=infinicloud
REMOTE_DIR=Backup/FOSSVPS/Docker
RESTORE_ROOT=/opt
BACKUP_SOURCE_ROOT=/opt
BACKUP_PROJECTS=NginxProxyManager,Resin,NewsFocus
BACKUP_RETENTION=7d
```

这些都可以在 `.env` 或命令行里覆盖。

---

## 用法

### 恢复模式

默认仍然兼容原先 restore 风格：

```bash
bash docker_restore.sh [backup-file] [options]
bash docker_restore.sh restore [backup-file] [options]
```

示例：

```bash
bash docker_restore.sh --config .env --yes
bash docker_restore.sh DockerBackup_2026-04-29_073625.tar.gz --config .env --yes
bash docker_restore.sh restore --config .env --dry-run
bash docker_restore.sh restore --config .env --yes --start-services
```

### 备份模式

```bash
bash docker_restore.sh backup [options]
```

示例：

```bash
bash docker_restore.sh backup --config .env
bash docker_restore.sh backup --config .env --dry-run
bash docker_restore.sh backup --backup-projects NginxProxyManager,Resin,NewsFocus
bash docker_restore.sh backup --retention 7d
```

---

## 重要参数

### 通用参数

- `-c, --config <file>` —— 从配置文件加载环境变量
- `--remote <name>` —— rclone remote 名称
- `--remote-dir <path>` —— 远程备份目录
- `--temp-dir <path>` —— 临时工作目录
- `--log-file <path>` —— 日志文件路径
- `--dry-run` —— 只预演，不落盘
- `--no-telegram` —— 禁止发送 Telegram 通知

### 恢复专用参数

- `--restore-root <path>` —— 恢复目标根目录
- `--projects <csv>` —— 指定校验项目列表
- `--start-services` —— 对可启动项目执行 `docker compose up -d`
- `-y, --yes` —— 跳过确认

### 备份专用参数

- `--backup-projects <csv>` —— 要打包的项目列表
- `--backup-root <path>` —— 这些项目所在根目录
- `--retention <age>` —— 远端清理阈值，对应 `rclone delete --min-age`
- `--required-space-kb <n>` —— 打包前要求的最小剩余空间

---

## 配置文件

示例 `.env`：

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

### 说明

- Telegram token / chat id 必须从 `.env` 或环境变量读取。
- 脚本正文里不再硬编码 Telegram 密钥。
- `pigz` 现在只是可选依赖；没有的话自动回退到普通 gzip 流程。
- 备份时只会纳入实际存在的目录。

---

## 备份流程

1. 检查依赖
2. 检查 rclone remote 是否存在
3. 检查临时目录可用空间
4. 从 `BACKUP_SOURCE_ROOT` 下筛出真实存在的项目目录
5. 生成 `DockerBackup_YYYY-MM-DD_HHMMSS.tar.gz`
6. 校验归档完整性
7. 上传到 `${REMOTE_NAME}:${REMOTE_DIR}`
8. 清理超过 `BACKUP_RETENTION` 的远端旧备份
9. 可选发送 Telegram 回执

---

## 恢复流程

1. 检查依赖
2. 检查 rclone remote 是否存在
3. 列出远端归档
4. 自动选最新或使用指定归档
5. 下载到临时目录
6. 预览归档内容
7. 如果没传 `--projects`，从归档中自动探测项目
8. 解压到 staging 目录
9. 复制到 `RESTORE_ROOT`
10. 将项目分成三类：
   - 已恢复且可启动
   - 已恢复但无 compose
   - 未恢复
11. 可选启动服务
12. 可选发送 Telegram 回执

---

## 安全提醒

- 永远先跑 `--dry-run`。
- restore 会覆盖目标根目录下的真实文件。
- `--start-services` 会直接启动恢复后的业务。
- 远端清理现在依赖 `rclone delete --min-age`，所以备份目录最好只放这类备份归档。
- 不要把真实 `.env` 秘钥提交进仓库。

---

## 推荐 cron 写法

如果要每天凌晨 3 点跑备份：

```bash
0 3 * * * /usr/bin/bash /opt/docker-restore-tool/docker_restore.sh backup --config /opt/docker-restore-tool/.env >> /var/log/docker_backup_cron.log 2>&1
```
