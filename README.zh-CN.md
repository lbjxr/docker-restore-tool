# docker-restore-tool

> 一个基于 Bash 的 Docker 项目备份恢复工具，用于把 `rclone` 远程存储中的归档恢复到新服务器。

`docker-restore-tool` 适合这样的运维场景：

- 你的 Docker 项目目录已经定期打包备份；
- 备份保存在 `rclone` 可访问的远程存储中；
- 你希望在新机器上按固定流程完成下载、解压、恢复与校验；
- 你想把这套流程沉淀成一个可复用、可审计、可公开发布的小工具。

---

## 功能特性

- 支持任意 `rclone` remote
- 可列出远程目录中的备份归档
- 未指定文件时自动选择最新备份
- 支持手动指定具体备份文件
- 先解压到 staging 目录，再复制到最终目标目录
- 支持按项目列表校验恢复结果
- 支持 `--yes` 跳过交互确认
- 支持 `--dry-run` 预演模式
- 支持通过配置文件加载参数
- 支持可选 Telegram 通知
- Bash 代码量小，便于阅读和二次修改

---

## 快速开始

### 1. 安装依赖

```bash
sudo apt-get update
sudo apt-get install -y tar pigz bsdextrautils curl
curl https://rclone.org/install.sh | sudo bash
```

### 2. 配置 `rclone`

```bash
rclone config
rclone listremotes
```

### 3. 测试远程目录

```bash
rclone ls infini:Backup/RN/Docker
```

### 4. 先执行预演

```bash
bash docker_restore.sh --dry-run
```

### 5. 再执行真实恢复

```bash
bash docker_restore.sh --yes
```

---

## 用法

```bash
bash docker_restore.sh [backup-file] [options]
```

### 参数说明

| 参数 | 说明 |
|---|---|
| `-c, --config <file>` | 从配置文件加载环境变量 |
| `--remote <name>` | `rclone` remote 名称 |
| `--remote-dir <path>` | 远程备份目录 |
| `--restore-root <path>` | 最终恢复目标根目录 |
| `--temp-dir <path>` | 临时工作目录 |
| `--log-file <path>` | 日志文件路径 |
| `--projects <csv>` | 用逗号分隔的项目名列表，用于恢复校验 |
| `-y, --yes` | 跳过交互确认 |
| `--dry-run` | 只显示计划动作，不改动文件 |
| `--no-telegram` | 即使设置了环境变量也禁用 Telegram 通知 |
| `-h, --help` | 显示帮助 |

---

## 示例

恢复默认 remote 中最新备份：

```bash
bash docker_restore.sh --yes
```

恢复指定备份：

```bash
bash docker_restore.sh DockerBackup_2026-04-05_160000.tar.gz --yes
```

使用自定义 remote 和恢复目录：

```bash
bash docker_restore.sh \
  --remote myremote \
  --remote-dir backups/docker \
  --restore-root /srv/apps \
  --yes
```

只校验指定项目：

```bash
bash docker_restore.sh --projects NginxProxyManager,openlist,komari --yes
```

使用配置文件运行：

```bash
cp config.example.env .env
bash docker_restore.sh --config .env --yes
```

---

## 配置文件

示例配置见：[`config.example.env`](./config.example.env)

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

## 工作流程

1. 检查依赖是否存在
2. 检查 `rclone` remote 是否存在
3. 列出远程目录里的备份文件
4. 自动选择最新备份或使用指定文件
5. 下载归档到临时目录
6. 预览归档内容
7. 解压到 staging 目录
8. 将 staging 中目标路径复制到最终恢复目录
9. 校验预期项目目录是否存在
10. 输出恢复后的后续操作建议

---

## 安全提醒

这个工具是“强操作型”脚本，用得顺手，也意味着需要你自己对环境负责。

### 风险点

- 会把真实文件恢复到目标目录（例如 `/opt`）
- 可能覆盖已有项目文件
- 假设归档内部路径与你设置的 `--restore-root` 一致
- 如果启用 Telegram 通知，会向外部服务发送执行结果
- 默认信任你本机 `rclone` 配置以及远端备份内容

### 建议实践

- 先跑 `--dry-run`
- 先在测试机验证
- 正式恢复前先做主机快照或额外备份
- 用 `tar -tzf` 先确认归档结构
- 不要把真实 Token、Chat ID、远端凭据、内网地址提交进仓库

---

## 当前限制

- 现在的校验逻辑只检查目录是否存在
- 不会验证容器是否真正启动成功
- 暂时不校验 checksum / 签名
- 默认只处理 `tar.gz` 归档
- 更适合目录级恢复，不是数据库逻辑恢复工具

---

## 后续改进方向

- 增加 SHA256 校验
- 增加归档 manifest 支持
- 从静态项目列表改为自动发现项目
- 恢复前自动备份目标目录
- 增加结构化日志
- 增加 restore 后健康检查
- 支持 `rsync` 方式复制
- 接入 `shellcheck` / `shfmt` 做 CI

---

## 项目结构

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

## License

MIT
