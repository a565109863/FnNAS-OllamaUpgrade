# FnNAS Ollama 升级脚本

适用于 FnNAS / 飞牛 NAS 上通过应用中心安装的 Ollama，提供交互式升级 Ollama、OpenWebUI 及相关配置的 Bash 脚本。

## 功能概览

- 从 GitHub 下载 Ollama 安装包（支持断点续传）
- 升级 CPU/NVIDIA 版（ROCm 为子选项，须先选 CPU）
- 升级 OpenWebUI（使用安装目录内 `bin/python3`）
- 修改 `OLLAMA_HOST` 监听地址（局域网 / 本机）
- 自动配置 OpenWebUI RAG 嵌入（Ollama + nomic-embed-text）
- 可选备份到 `backup/` 目录
- 保存 / 加载上次配置，支持一键重复升级
- 下载完成后再停止 ollama、open-webui 进程

## 环境要求

- FnNAS / 飞牛 NAS，已安装 Ollama 应用
- **须使用 root 权限运行**（写入应用安装目录、修改 `service-setup`、关闭进程等操作需要 root）
- 默认安装路径：`/vol1/@appcenter/ai_installer`（也支持手动指定）
- 需要 `curl`、`tar`（支持 `--zstd`）、`bash`
- 升级 OpenWebUI 需要已存在 `{安装目录}/open-webui/bin/python3`

## 快速开始

```bash
cd /path/to/upgrade-ollama
sudo chmod +x upgrade-ollama.sh
sudo ./upgrade-ollama.sh
```

首次运行按提示逐步选择；确认后会将配置保存到 `.upgrade-ollama.conf`。再次运行时可选择加载配置直接执行。

## 交互选项说明

| 步骤 | 说明 |
|------|------|
| 1. 安装目录 | 自动扫描 `/vol*/@appcenter/ai_installer`，可手填路径 |
| 2. 代理 | 是否通过 ghproxy 加速 GitHub 下载 |
| 3. 版本 | 列出最新 10 个版本，回车默认选最新版 |
| 4. 安装组件 | 先选 CPU/NVIDIA 版；若选「是」，可再选 ROCm 版（AMD GPU 加速，不可单独安装） |
| 5. service-setup | 修改 `OLLAMA_HOST`；可选开启/关闭 `OLLAMA_IGPU_ENABLE`（核显加速） |
| 6. OpenWebUI | 是否升级；可选 **在线安装** 或 **先下载再安装（离线，可复用本地包）** |
| 7. 备份 | 是否备份 `ollama` / `open-webui`；是否备份 `service-setup` |
| 8. 清理 | 是否删除已下载的安装包 |

至少需选择一项升级操作（Ollama 组件、OpenWebUI、`OLLAMA_HOST` 或核显加速修改）。

## 升级流程

脚本按以下顺序执行：

1. **下载** — 安装包保存到 `download/`（ollama 与 open-webui 分包存放）
2. **关闭进程** — 安装包下载完成后再停止 ollama、open-webui
3. **备份** — 若启用，将 `ollama`、`open-webui` 复制到 `backup/`；`service-setup` 仅在首次修改前备份一次
4. **解压** — 解压到 `{安装目录}/ollama`（CPU 包提供主程序，ROCm 包补充 `lib/ollama/rocm`）
5. **修改 OLLAMA_HOST / 核显加速** — 编辑 `/var/apps/ai_installer/cmd/service-setup`（可选）
6. **升级 OpenWebUI** — 从本地或在线 pip 安装，添加 RAG 嵌入配置（若尚未存在）
7. **清理** — 可选删除下载目录

## 目录结构

```
upgrade-ollama/
├── upgrade-ollama.sh          # 主脚本
├── .upgrade-ollama.conf       # 保存的配置（自动生成）
├── backup/                    # 备份目录
│   └── {时间戳}/
│       ├── ollama/
│       ├── open-webui/
│       └── service-setup
├── download/                  # 下载目录
│   ├── ollama-{版本}/         # Ollama 安装包
│   │   ├── ollama-linux-amd64.tar.zst
│   │   └── ollama-linux-amd64-rocm.tar.zst
│   └── open-webui-pypi/       # OpenWebUI pip 依赖包
```

安装目录（默认 `/vol1/@appcenter/ai_installer`）：

```
ai_installer/
├── ollama/          # Ollama 主程序
└── open-webui/      # OpenWebUI 虚拟环境
```

## 升级完成后

脚本结束时会提示：

> Ollama 应用已停用，请前往应用中心重新启用 Ollama 应用以使更新生效

请在 NAS **应用中心** 手动重新启用 Ollama 应用，以加载新版本并启动服务。

## 常见场景

### 仅升级 Ollama

选择安装 CPU 版（有 NVIDIA 显卡同样选 CPU 版），不装 AMD 显卡则跳过 ROCm 子选项，OpenWebUI 按需选择。

### 仅升级 OpenWebUI

CPU 版选「否」（不会出现 ROCm 选项），OpenWebUI 选「是」。不会下载 Ollama 安装包，也不会备份 / 替换 `ollama` 目录。

### AMD 显卡

先选 **CPU 版**（主程序），再在子选项中勾选 **ROCm 版**（GPU 库）。脚本先解压 CPU 包，再解压 ROCm 包。

### 允许局域网访问 Ollama

在步骤 5 选择 `0.0.0.0:11434`，升级完成后重新启用应用生效。

## 注意事项

- **必须使用 root 运行**，普通用户会因权限不足导致写入安装目录、修改 `/var/apps/ai_installer/cmd/service-setup` 或关闭进程失败
- 升级 Ollama 时会清空并重建 `{安装目录}/ollama`，建议开启备份
- `open-webui` 备份体积较大，跨磁盘复制可能耗时较长，请耐心等待
- 修改 `service-setup` 前可选备份到 `backup/` 目录
- 加载配置文件并确认后，将跳过交互步骤直接执行
