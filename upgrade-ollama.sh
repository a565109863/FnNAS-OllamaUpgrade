#!/bin/bash
set -euo pipefail

# ====================== 基础配置 ======================
MAX_RETRY=10
WAIT_SEC=3
TEST_DIR="/tmp/ollama_test_extract"

PKG_CPU="ollama-linux-amd64.tar.zst"
PKG_ROCM="ollama-linux-amd64-rocm.tar.zst"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backup"
DOWNLOAD_DIR="${SCRIPT_DIR}/download"
PYPI_MIRROR="https://mirrors.aliyun.com/pypi/simple/"
CONFIG_FILE="${SCRIPT_DIR}/.upgrade-ollama.conf"
SERVICE_SETUP="/var/apps/ai_installer/cmd/service-setup"

# ====================== 工具函数 ======================
# 下载：断点续传，不删除未完成文件
download_file() {
    local url="$1"
    local file="$2"
    local retry=0

    echo "⏬ 下载: $file"
    echo "🌐 断点续传"

    while [ $retry -lt $MAX_RETRY ]; do
        echo "========================================"
        echo "尝试 $((retry+1))/${MAX_RETRY}"

        if curl -C - -L \
            --connect-timeout 60 \
            --progress-bar \
            -o "$file" \
            "$url"; then
            echo "✅ 下载成功"
            return 0
        fi

        echo "⚠️  下载中断，将继续断点续传..."
        retry=$((retry+1))
        sleep $WAIT_SEC
    done

    echo "❌ 下载失败"
    exit 1
}

confirm() {
    local tip="$1"
    local def="$2"
    read -p "${tip} (y/n) [默认$def]: " ans
    [ -z "$ans" ] && ans="$def"
    case $ans in y|Y) return 0 ;; *) return 1 ;; esac
}

# ROCm 为 CPU 版子项；未装 CPU 时不安装 ROCm
normalize_rocm_option() {
    if [ "${do_cpu:-0}" -eq 0 ] && [ "${do_rocm:-0}" -eq 1 ]; then
        do_rocm=0
        echo "ℹ️  未安装 CPU 版，已忽略 ROCm 选项"
    fi
}

# 备份目录到 backup 目录
backup_to_script_dir() {
    local name="$1"
    local src="${BASE_DIR}/${name}"
    local dest="${BACKUP_SESSION}/${name}"

    mkdir -p "$BACKUP_SESSION"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        echo "📦 正在备份: $name ..."
        if cp -a "$src" "$dest"; then
            echo "📦 已备份: $dest"
        else
            echo "❌ 备份失败: $src"
            exit 1
        fi
    else
        echo "⚠️  跳过备份（目录不存在）: $src"
    fi
}

# 解压到目标目录（兼容不支持 --strip-components 的 tar）
extract_pkg() {
    local pkg="$1"
    local dest="$2"
    local tmp="${TEST_DIR}_$$"

    rm -rf "$tmp"
    mkdir -p "$tmp" "$dest"

    echo "📦 解压: $(basename "$pkg")"
    if command -v pv >/dev/null 2>&1; then
        pv -pteb "$pkg" | tar --zstd -xf - -C "$tmp"
    else
        tar --zstd -xvf "$pkg" -C "$tmp" 2>&1 \
            | awk '{printf "\r📦 已解压 %d 个文件...", NR; fflush()}'
        echo
    fi
    echo "✅ 解压完成: $(basename "$pkg")"

    cp -a "$tmp"/. "$dest"/
    rm -rf "$tmp"
}

get_ollama_host() {
    if [ -f "$SERVICE_SETUP" ]; then
        grep -E '^export OLLAMA_HOST=' "$SERVICE_SETUP" | head -1 \
            | sed 's/^export OLLAMA_HOST=//;s/"//g;s/^'\''//;s/'\''$//'
    fi
}

apply_ollama_host() {
    local target="$1"

    if [ ! -f "$SERVICE_SETUP" ]; then
        echo "❌ 文件不存在: $SERVICE_SETUP"
        return 1
    fi
    if ! grep -qE '^export OLLAMA_HOST=' "$SERVICE_SETUP"; then
        echo "❌ 未找到 OLLAMA_HOST 配置"
        return 1
    fi

    mkdir -p "$BACKUP_SESSION"
    cp -a "$SERVICE_SETUP" "${BACKUP_SESSION}/service-setup"
    sed -i "s|^export OLLAMA_HOST=.*|export OLLAMA_HOST=\"${target}\"|" "$SERVICE_SETUP"
    echo "✅ OLLAMA_HOST 已改为: ${target}"
}

apply_rag_embedding() {
    if [ ! -f "$SERVICE_SETUP" ]; then
        echo "❌ 文件不存在: $SERVICE_SETUP"
        return 1
    fi
    if ! grep -qE '^SERVICE_COMMAND=' "$SERVICE_SETUP"; then
        echo "❌ 未找到 SERVICE_COMMAND 配置"
        return 1
    fi

    local engine_exists=0 model_exists=0
    grep -qE '^export RAG_EMBEDDING_ENGINE=' "$SERVICE_SETUP" && engine_exists=1
    grep -qE '^export RAG_EMBEDDING_MODEL=' "$SERVICE_SETUP" && model_exists=1

    if [ $engine_exists -eq 1 ] && [ $model_exists -eq 1 ]; then
        echo "ℹ️  RAG 嵌入配置已存在，跳过"
        return 0
    fi

    mkdir -p "$BACKUP_SESSION"
    cp -a "$SERVICE_SETUP" "${BACKUP_SESSION}/service-setup"
    local tmp="${SERVICE_SETUP}.tmp.$$"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == SERVICE_COMMAND=* ]]; then
            [ $engine_exists -eq 0 ] && echo 'export RAG_EMBEDDING_ENGINE=ollama'
            [ $model_exists -eq 0 ] && echo 'export RAG_EMBEDDING_MODEL=nomic-embed-text'
        fi
        echo "$line"
    done < "$SERVICE_SETUP" > "$tmp"
    mv "$tmp" "$SERVICE_SETUP"
    echo "✅ 已添加 RAG 嵌入配置"
}

collect_pids() {
    local pattern pid result=""
    for pattern in "$@"; do
        while IFS= read -r pid; do
            [ -z "$pid" ] && continue
            [ "$pid" -eq $$ ] && continue
            case " $result " in
                *" $pid "*) ;;
                *) result="$result $pid" ;;
            esac
        done < <(pgrep -f "$pattern" 2>/dev/null || true)
    done
    echo "$result" | xargs
}

stop_process_if_running() {
    local name="$1"
    shift
    local pids remaining

    pids=$(collect_pids "$@")
    if [ -z "$pids" ]; then
        echo "ℹ️  ${name} 未运行"
        return 0
    fi

    echo "🛑 关闭 ${name} 进程: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 2
    remaining=$(collect_pids "$@")
    if [ -n "$remaining" ]; then
        echo "🛑 强制关闭 ${name} 进程: $remaining"
        # shellcheck disable=SC2086
        kill -9 $remaining 2>/dev/null || true
        sleep 1
        remaining=$(collect_pids "$@")
    fi
    if [ -n "$remaining" ]; then
        echo "⚠️  ${name} 未能完全关闭: $remaining"
    else
        echo "✅ ${name} 已关闭"
    fi
}

stop_all_services() {
    echo -e "\n▶️  检查并关闭进程"
    # open-webui 依赖 ollama，先关 open-webui
    stop_process_if_running "open-webui" \
        "${OWUI_DIR}/bin/python" \
        "${OWUI_DIR}/bin/open-webui" \
        "${OWUI_DIR}/" \
        "open-webui serve" \
        "open_webui"
    stop_process_if_running "ollama" \
        "${TARGET_DIR}/bin/ollama" \
        "ollama serve"
}

download_owui_packages() {
    local py="$1"
    local count

    echo "⏬ 下载 open-webui 及依赖到: ${OWUI_PKG_DIR}"
    echo "ℹ️  正在解析依赖，请稍候（此阶段目录可能暂时为空）..."
    mkdir -p "$OWUI_PKG_DIR"
    "$py" -m pip download pip open-webui \
        -d "$OWUI_PKG_DIR" \
        -i "$PYPI_MIRROR" \
        --progress-bar \
        --no-cache-dir
    count=$(owui_pkg_file_count "$OWUI_PKG_DIR")
    if [ "$count" -eq 0 ]; then
        echo "❌ 未下载到任何包文件: $OWUI_PKG_DIR"
        exit 1
    fi
    echo "✅ 依赖包下载完成 (${count} 个文件)"
}

owui_pkg_file_count() {
    find "$1" -type f \( -name '*.whl' -o -name '*.tar.gz' \) 2>/dev/null | wc -l | tr -d ' '
}

prepare_owui_packages() {
    local py="$1"
    local count

    if [ "${reuse_owui_pkg:-n}" = "y" ]; then
        count=$(owui_pkg_file_count "$OWUI_PKG_DIR")
        if [ "$count" -gt 0 ]; then
            echo "♻️  复用本地依赖包 (${count} 个文件): ${OWUI_PKG_DIR}"
            return 0
        fi
        echo "⚠️  本地包目录为空，改为重新下载"
    fi
    download_owui_packages "$py"
}

install_owui_from_local() {
    local py="$1"

    echo "📦 从本地安装 pip 与 open-webui"
    if ! "$py" -m pip install --upgrade --no-index --find-links "$OWUI_PKG_DIR" pip; then
        echo "❌ pip 升级失败"
        return 1
    fi
    if ! "$py" -m pip install --upgrade --no-index --find-links "$OWUI_PKG_DIR" open-webui; then
        echo "❌ open-webui 安装失败"
        return 1
    fi
    echo "✅ open-webui 安装完成"
}

install_owui_online() {
    local py="$1"

    echo "📦 在线安装 pip 与 open-webui"
    if ! "$py" -m pip install --upgrade -i "$PYPI_MIRROR" pip; then
        echo "❌ pip 升级失败"
        return 1
    fi
    if ! "$py" -m pip install --upgrade -i "$PYPI_MIRROR" open-webui; then
        echo "❌ open-webui 安装失败"
        return 1
    fi
    echo "✅ open-webui 安装完成"
}

# 在线安装时不下载/复用本地包
normalize_owui_install_mode() {
    owui_install_mode="${owui_install_mode:-local}"
    if [ "$owui_install_mode" != "local" ] && [ "$owui_install_mode" != "online" ]; then
        owui_install_mode="local"
    fi
    if [ "$owui_install_mode" = "online" ]; then
        reuse_owui_pkg="n"
    fi
}

show_finish_message() {
    echo -e "\n============================================="
    echo "🎉 升级完成！"
    echo "📌 Ollama 应用已停用，请前往应用中心重新启用 Ollama 应用以使更新生效"
    echo "============================================="
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
BASE_DIR=${BASE_DIR}
USE_GHPROXY=${USE_GHPROXY}
OLLAMA_VERSION=${OLLAMA_VERSION}
do_cpu=${do_cpu}
do_rocm=${do_rocm}
upgrade_owui=${upgrade_owui}
owui_install_mode=${owui_install_mode}
reuse_owui_pkg=${reuse_owui_pkg}
do_backup=${do_backup}
clean_ollama_pkg=${clean_ollama_pkg}
clean_owui_pkg=${clean_owui_pkg}
modify_ollama_host=${modify_ollama_host}
EOF
    echo "💾 配置已保存: $CONFIG_FILE"
}

load_config() {
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    clean_ollama_pkg="${clean_ollama_pkg:-${clean_temp:-n}}"
    clean_owui_pkg="${clean_owui_pkg:-${clean_temp:-n}}"
    reuse_owui_pkg="${reuse_owui_pkg:-n}"
    owui_install_mode="${owui_install_mode:-local}"
}

show_config_summary() {
    echo "安装目录:    $BASE_DIR"
    echo "版本:        $OLLAMA_VERSION"
    echo "下载目录:    ${DOWNLOAD_DIR}"
    if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
        echo "  ollama:      ${DOWNLOAD_DIR}/ollama-${OLLAMA_VERSION}"
    fi
    if [ "$upgrade_owui" = "y" ]; then
        if [ "${owui_install_mode:-local}" = "local" ]; then
            echo "  open-webui:  ${DOWNLOAD_DIR}/open-webui-pypi"
        fi
    fi
    echo "代理:        $([ "$USE_GHPROXY" = "y" ] && echo "开" || echo "关")"
    echo "CPU 安装:    $([ $do_cpu = 1 ] && echo "是" || echo "否")"
    if [ $do_cpu -eq 1 ]; then
        echo "  └ ROCm:      $([ $do_rocm = 1 ] && echo "是" || echo "否")"
    fi
    if [ "${modify_ollama_host:-n}" != "n" ]; then
        echo "OLLAMA_HOST: 改为 ${modify_ollama_host}"
    else
        echo "OLLAMA_HOST: 不修改"
    fi
    echo "升级OWUI:    $([ "$upgrade_owui" = "y" ] && echo "是" || echo "否")"
    if [ "$upgrade_owui" = "y" ]; then
        if [ "${owui_install_mode:-local}" = "online" ]; then
            echo "  └ 安装方式:  在线安装"
        else
            echo "  └ 安装方式:  先下载再安装（离线）"
            echo "  └ 复用本地包: $([ "${reuse_owui_pkg:-n}" = "y" ] && echo "是（跳过下载）" || echo "否")"
        fi
    fi
    echo "备份:        $([ "${do_backup:-y}" = "y" ] && echo "是" || echo "否")"
    if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
        echo "清理ollama:  $([ "${clean_ollama_pkg:-y}" = "y" ] && echo "是" || echo "否")"
    fi
    if [ "$upgrade_owui" = "y" ] && [ "${owui_install_mode:-local}" = "local" ]; then
        echo "清理OWUI:    $([ "${clean_owui_pkg:-y}" = "y" ] && echo "是" || echo "否")"
    fi
}

# ====================== 选项选择 ======================
clear
echo "============================================="
echo "         Ollama 安装脚本（断点续传版）"
echo "============================================="

load_config_mode=0
if [ -f "$CONFIG_FILE" ]; then
    echo -e "\n📄 发现配置文件: $CONFIG_FILE"
    load_config
    normalize_rocm_option
    normalize_owui_install_mode
    echo "---------------------------------------------"
    show_config_summary
    echo "---------------------------------------------"
    if confirm "加载以上配置" "y"; then
        load_config_mode=1
        normalize_rocm_option
        normalize_owui_install_mode
        if [ ! -d "$BASE_DIR" ]; then
            echo "❌ 配置中的安装目录不存在: $BASE_DIR"
            exit 1
        fi
        if [ $do_cpu -eq 0 ] && [ $do_rocm -eq 0 ] && [ "$upgrade_owui" != "y" ] && [ "${modify_ollama_host:-n}" = "n" ]; then
            echo "❌ 配置中未选择任何升级操作"
            exit 1
        fi
        save_config
    else
        load_config_mode=0
    fi
fi

if [ $load_config_mode -eq 0 ]; then
    # 1. 目录
    echo -e "\n[1/8] 选择安装目录"
    found_dirs=()
    for path in /vol*/@appcenter/ai_installer; do
        [ -d "$path" ] && found_dirs+=("$path")
    done
    if [ ${#found_dirs[@]} -gt 0 ]; then
        for i in "${!found_dirs[@]}"; do echo "$((i+1))) ${found_dirs[$i]}"; done
    else
        echo "未自动发现安装目录"
    fi
    echo "0) 手动输入路径"
    if [ ${#found_dirs[@]} -eq 1 ]; then
        read -p "请选择序号或直接输入路径 [默认1]: " dir_input
        [ -z "$dir_input" ] && dir_input=1
    else
        read -p "请选择序号或直接输入路径: " dir_input
    fi

    if [[ "$dir_input" == /* ]]; then
        BASE_DIR="$dir_input"
    elif [ "$dir_input" = "0" ]; then
        read -p "请输入安装路径: " BASE_DIR
    elif [[ "$dir_input" =~ ^[0-9]+$ ]] && [ "$dir_input" -ge 1 ] && [ "$dir_input" -le ${#found_dirs[@]} ]; then
        BASE_DIR="${found_dirs[$((dir_input-1))]}"
    elif [ -n "$dir_input" ]; then
        BASE_DIR="$dir_input"
    else
        echo "❌ 未选择目录"
        exit 1
    fi
    if [ ! -d "$BASE_DIR" ]; then
        echo "❌ 目录不存在: $BASE_DIR"
        exit 1
    fi

    # 2. 代理
    echo -e "\n[2/8] 使用 ghproxy 代理？"
    USE_GHPROXY="n"
    confirm "启用代理" "n" && USE_GHPROXY="y"

    # 3. 版本
    echo -e "\n[3/8] 选择 Ollama 版本"
    TAGS=$(curl -s --connect-timeout 10 https://api.github.com/repos/ollama/ollama/tags | grep '"name":' | sed 's/.*"v//;s/".*//' | head -10)
    LATEST=$(echo "$TAGS" | head -n1)
    DEFAULT_TAG_IDX=$(echo "$TAGS" | grep -nx "^${LATEST}$" | head -1 | cut -d: -f1)
    [ -z "$DEFAULT_TAG_IDX" ] && DEFAULT_TAG_IDX=1
    echo "最新10个版本:"
    echo "$TAGS" | nl -w2 -s') '
    echo "最新版: v${LATEST} (序号 ${DEFAULT_TAG_IDX})"
    read -p "输入序号/版本号 [默认${DEFAULT_TAG_IDX}]: " vinput
    [ -z "$vinput" ] && vinput=$DEFAULT_TAG_IDX
    if [[ "$vinput" =~ ^[0-9]+$ ]]; then
        OLLAMA_VERSION=$(echo "$TAGS" | sed -n "${vinput}p")
        if [ -z "$OLLAMA_VERSION" ]; then
            echo "❌ 无效序号: $vinput"
            exit 1
        fi
    else
        OLLAMA_VERSION="$vinput"
    fi

    # 4. 组件
    echo -e "\n[4/8] 安装组件"
    do_cpu=0; do_rocm=0
    confirm "安装 CPU/NVIDIA 版" "y" && do_cpu=1
    if [ $do_cpu -eq 1 ]; then
        confirm "  └ 安装 AMD ROCm 版（GPU 加速）" "y" && do_rocm=1
    fi

    # 5. OLLAMA_HOST
    echo -e "\n[5/8] 修改 service-setup 中的 OLLAMA_HOST"
    modify_ollama_host="n"
    if [ -f "$SERVICE_SETUP" ]; then
        current_host=$(get_ollama_host || true)
        echo "配置文件: $SERVICE_SETUP"
        echo "当前值: ${current_host:-未知}"
        echo "1) 改为 0.0.0.0:11434（允许局域网访问）"
        echo "2) 改为 127.0.0.1:11434（仅本机访问）"
        echo "0) 不修改"
        read -p "请选择 [默认0]: " host_choice
        [ -z "$host_choice" ] && host_choice=0
        case "$host_choice" in
            1) modify_ollama_host="0.0.0.0:11434" ;;
            2) modify_ollama_host="127.0.0.1:11434" ;;
        esac
    else
        echo "⚠️  未找到 $SERVICE_SETUP，跳过"
    fi

    # 6. 升级 OpenWebUI
    echo -e "\n[6/8] 是否升级 OpenWebUI"
    upgrade_owui="n"
    owui_install_mode="local"
    reuse_owui_pkg="n"
    confirm "升级" "y" && upgrade_owui="y"
    if [ "$upgrade_owui" = "y" ]; then
        echo "  1) 先下载再安装（离线，可复用本地包）"
        echo "  2) 在线安装（直接从 PyPI 安装）"
        read -p "  请选择安装方式 [默认1]: " owui_mode_choice
        [ -z "$owui_mode_choice" ] && owui_mode_choice=1
        if [ "$owui_mode_choice" = "2" ]; then
            owui_install_mode="online"
        fi
        if [ "$owui_install_mode" = "local" ]; then
            owui_local_dir="${DOWNLOAD_DIR}/open-webui-pypi"
            owui_local_count=$(owui_pkg_file_count "$owui_local_dir")
            if [ "$owui_local_count" -gt 0 ]; then
                echo "  发现本地依赖包: ${owui_local_dir} (${owui_local_count} 个文件)"
                confirm "  └ 复用本地包，跳过下载" "y" && reuse_owui_pkg="y"
            fi
        fi
    fi

    # 7. 备份
    echo -e "\n[7/8] 升级前是否备份到 ${BACKUP_DIR}？"
    do_backup="n"
    confirm "备份" "y" && do_backup="y"

    # 8. 清理
    echo -e "\n[8/8] 安装后清理"
    clean_ollama_pkg="n"
    clean_owui_pkg="n"
    if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
        confirm "清理 ollama 安装包 (${DOWNLOAD_DIR}/ollama-${OLLAMA_VERSION})" "y" && clean_ollama_pkg="y"
    fi
    if [ "$upgrade_owui" = "y" ] && [ "${owui_install_mode:-local}" = "local" ]; then
        confirm "清理 open-webui 依赖包 (${DOWNLOAD_DIR}/open-webui-pypi)" "y" && clean_owui_pkg="y"
    fi
fi

modify_ollama_host="${modify_ollama_host:-n}"
do_backup="${do_backup:-y}"
clean_ollama_pkg="${clean_ollama_pkg:-n}"
clean_owui_pkg="${clean_owui_pkg:-n}"
reuse_owui_pkg="${reuse_owui_pkg:-n}"
owui_install_mode="${owui_install_mode:-local}"

normalize_rocm_option
normalize_owui_install_mode

if [ $do_cpu -eq 0 ] && [ $do_rocm -eq 0 ] && [ "$upgrade_owui" != "y" ] && [ "$modify_ollama_host" = "n" ]; then
    echo "❌ 未选择任何升级操作"
    exit 1
fi

# ====================== 路径 ======================
OLLAMA_PKG_DIR="${DOWNLOAD_DIR}/ollama-${OLLAMA_VERSION}"
OWUI_PKG_DIR="${DOWNLOAD_DIR}/open-webui-pypi"

CPU_PKG="${OLLAMA_PKG_DIR}/${PKG_CPU}"
ROCM_PKG="${OLLAMA_PKG_DIR}/${PKG_ROCM}"

TARGET_DIR="${BASE_DIR}/ollama"
OWUI_DIR="${BASE_DIR}/open-webui"

if [ "$USE_GHPROXY" = "y" ]; then
    URL_PREFIX="https://ghproxy.com/https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}"
else
    URL_PREFIX="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}"
fi

# ====================== 确认 ======================
if [ $load_config_mode -eq 0 ]; then
    clear
    echo "============================================="
    echo "              配置确认"
    echo "============================================="
    show_config_summary
    echo "============================================="

    if ! confirm "确认执行" "y"; then
        echo "🛑 已取消"
        exit 0
    fi

    save_config
fi

# ====================== 执行 ======================
BACKUP_SESSION="${BACKUP_DIR}/$(date +%Y%m%d_%H%M%S)"

echo -e "\n============================================="
echo "          开始执行"
echo "============================================="

# 1. 下载 ollama 安装包
if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
    echo -e "\n▶️  【1/5】下载 ollama 安装包"
    mkdir -p "$OLLAMA_PKG_DIR"
    if [ $do_cpu -eq 1 ]; then
        download_file "${URL_PREFIX}/${PKG_CPU}" "$CPU_PKG"
    fi
    if [ $do_rocm -eq 1 ]; then
        download_file "${URL_PREFIX}/${PKG_ROCM}" "$ROCM_PKG"
    fi
fi

# 2. 下载 open-webui 依赖包（仅离线模式）
if [ "$upgrade_owui" = "y" ]; then
    OWUI_PY="${OWUI_DIR}/bin/python3"
    if [ ! -x "$OWUI_PY" ]; then
        echo "❌ 未找到 $OWUI_PY"
        exit 1
    fi
    if [ "${owui_install_mode:-local}" = "local" ]; then
        if [ "${reuse_owui_pkg:-n}" = "y" ]; then
            echo -e "\n▶️  【2/5】准备 open-webui 依赖包（复用本地）"
        else
            echo -e "\n▶️  【2/5】下载 open-webui 依赖包"
        fi
        prepare_owui_packages "$OWUI_PY"
    else
        echo -e "\n▶️  【2/5】跳过 open-webui 下载（在线安装）"
    fi
fi

# 3. 关闭服务（安装包下载完成后再关闭）
stop_all_services

# 4. 备份
cd "$BASE_DIR"
if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ] || [ "$upgrade_owui" = "y" ]; then
    if [ "$do_backup" = "y" ]; then
        echo -e "\n▶️  【4/5】备份到 ${BACKUP_SESSION}"
        if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
            backup_to_script_dir "ollama"
        fi
        if [ "$upgrade_owui" = "y" ]; then
            backup_to_script_dir "open-webui"
        fi
    else
        echo -e "\n▶️  【4/5】跳过备份"
    fi
    if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
        rm -rf "$TARGET_DIR"
        mkdir -p "$TARGET_DIR"
    fi
fi

# 5. 解压
if [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
    echo -e "\n▶️  【5/5】解压到 ${TARGET_DIR}"
    if [ $do_cpu -eq 1 ]; then
        extract_pkg "$CPU_PKG" "$TARGET_DIR"
    fi
    if [ $do_rocm -eq 1 ]; then
        extract_pkg "$ROCM_PKG" "$TARGET_DIR"
    fi
fi

# 4. 修改 OLLAMA_HOST
if [ "$modify_ollama_host" != "n" ]; then
    echo -e "\n▶️  修改 OLLAMA_HOST"
    apply_ollama_host "$modify_ollama_host"
fi

# 5. 升级 OpenWebUI
if [ "$upgrade_owui" = "y" ]; then
    echo -e "\n▶️  升级 OpenWebUI"
    cd "$OWUI_DIR"
    if [ "${owui_install_mode:-local}" = "online" ]; then
        if ! install_owui_online "$OWUI_PY"; then
            echo "❌ OpenWebUI 升级失败"
            exit 1
        fi
    elif ! install_owui_from_local "$OWUI_PY"; then
        echo "❌ OpenWebUI 升级失败"
        exit 1
    fi
    echo -e "\n▶️  配置 RAG 嵌入"
    apply_rag_embedding || true
fi

# 清理
if [ "${clean_ollama_pkg}" = "y" ] && [ -d "$OLLAMA_PKG_DIR" ]; then
    echo -e "\n🗑️  清理 ollama 安装包: $OLLAMA_PKG_DIR"
    rm -rf "$OLLAMA_PKG_DIR"
elif [ $do_cpu -eq 1 ] || [ $do_rocm -eq 1 ]; then
    echo -e "\nℹ️  保留 ollama 安装包: $OLLAMA_PKG_DIR"
fi
if [ "$upgrade_owui" = "y" ] && [ "${owui_install_mode:-local}" = "local" ]; then
    if [ "${clean_owui_pkg}" = "y" ] && [ -d "$OWUI_PKG_DIR" ]; then
        echo "🗑️  清理 open-webui 依赖包: $OWUI_PKG_DIR"
        rm -rf "$OWUI_PKG_DIR"
    else
        echo "ℹ️  保留 open-webui 依赖包: $OWUI_PKG_DIR"
    fi
fi

rm -rf "$TEST_DIR"

# ====================== 完成 ======================
show_finish_message