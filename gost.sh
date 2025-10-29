#!/usr/bin/env bash

#----------------------------------------------------------------------------------
# Gost 转发面板管理脚本 (v20.0 - Debian/Alpine/Direct)
#
# 作者: Gemini
# 描述: 一个用于安装、配置和管理 Gost 的交互式脚本。
# 兼容性: Debian (systemd), Alpine (OpenRC), Generic (direct)
#
# --- 更新日志 ---
# ... (v19.8 及更早版本日志省略) ...
#
#   - [V20.0] 重构 detect_china_ip 函数，采用多 API 轮询:
#       1. [检测] 内置一个 API 列表 (ifconfig.co, ip-api.com, ip.sb)。
#       2. 脚本会依次尝试所有 API。
#       3. 只要有任何一个 API 返回 "CN"，立即判定为中国大陆并切换到手动模式。
#       4. 修复了 v19.8 中询问用户时 "while true" 循环的逻辑错误。
#----------------------------------------------------------------------------------


# --- 全局变量 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 路径和文件名
SCRIPT_FILE_PATH=$(readlink -f "$0")
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/gost"
CONFIG_FILE="${CONFIG_DIR}/services.conf"

LOG_FILE="/var/log/gost.log"
PID_FILE="/var/run/gost.pid"

SERVICE_FILE_SYSTEMD="/etc/systemd/system/gost.service"
SERVICE_FILE_OPENRC="/etc/init.d/gost"

# Gost 仓库
GOST_REPO="go-gost/gost"

# 系统变量 (稍后自动检测)
OS_TYPE=""
ARCH=""
INIT_SYSTEM=""

# --- 辅助函数 ---

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "此脚本必须以 root 权限运行。"
        exit 1
    fi
}

pause() {
    read -p "按 [Enter] 键继续..."
}

# (v19.4) 增加 OpenRC 检查 (修复 openrc 假性 "started" 状态)
check_service_status() {
    case $INIT_SYSTEM in
    systemd)
        if systemctl is-active --quiet gost; then
            return 0 # Success
        else
            return 1 # Failure
        fi
        ;;
    openrc | direct)
        # (v19.4 修复)
        # OpenRC 在 "start" 命令返回 0 时会报告 "started"，
        # 即使进程因为配置为空而没有启动。
        # 因此，OpenRC 和 Direct 模式都必须检查 PID 文件。
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" >/dev/null 2>&1; then
            return 0
        else
            # 清理无效的 PID 文件
            if [ -f "$PID_FILE" ]; then
                rm -f "$PID_FILE"
            fi
            return 1
        fi
        ;;
    esac
    return 1 # Default to failure
}

# 辅助函数: 核心依赖预检查
check_core_dependencies() {
    local missing_deps=()
    # (v16.1) 增加 openssl 检查
    for cmd in curl tar openssl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "检测到脚本核心依赖缺失: ${missing_deps[*]}"
        print_warning "请运行 '1. 安装 Gost' 来自动安装依赖。"
        pause
    fi
}


# --- 检测函数 ---

# 1. 检测操作系统 (v19.0 恢复 Alpine)
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "debian" ] || [ "$ID_LIKE" = "debian" ]; then
            OS_TYPE="debian"
        elif [ "$ID" = "alpine" ]; then
            OS_TYPE="alpine"
        else
            print_error "不支持的操作系统: $ID (仅支持 Debian/Alpine)"
            exit 1
        fi
    elif [ -f /etc/alpine-release ]; then
         # 兼容没有 os-release 的老版本 Alpine
        OS_TYPE="alpine"
    else
        print_error "无法检测到 /etc/os-release"
        exit 1
    fi
    print_info "检测到操作系统: $OS_TYPE"
}

# 2. 检测架构
detect_arch() {
    case $(uname -m) in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64)
        ARCH="arm64"
        ;;
    armv7l)
        ARCH="armv7"
        ;;
    *)
        print_error "不支持的架构: $(uname -m)"
        exit 1
        ;;
    esac
    print_info "检测到架构: $ARCH"
}

# 3. 检测初始化系统 (v19.0 恢复 OpenRC)
detect_init_system() {
    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif [ -f /sbin/openrc ] && [ "$OS_TYPE" = "alpine" ]; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="direct"
        print_warning "未检测到 systemd 或 openrc。将使用 direct 进程管理模式。"
        print_warning "在此模式下，gost 不会自动开机启动。"
    fi
    print_info "检测到初始化系统: $INIT_SYSTEM"
}

# (v19.0) 恢复 Alpine 专用的 Bash 检查
check_bash_dependency() {
    if [ "$OS_TYPE" = "alpine" ] && [ ! -f /bin/bash ]; then
        print_error "检测到 Alpine 系统, 但缺少 /bin/bash。"
        print_info "此脚本依赖 bash 运行。"
        print_info "正在尝试自动安装 bash..."
        if ! command -v apk >/dev/null 2>&1; then
            print_error "未找到 'apk' 命令。请手动安装 bash。"
            exit 1
        fi
        apk add --no-cache bash
        if [ $? -ne 0 ]; then
            print_error "bash 安装失败。请手动运行 'apk add bash' 后重试。"
            exit 1
        fi
        print_success "bash 已安装。请重新运行脚本: /bin/bash $0"
        exit 0
    fi
}


# 4. 检测中国大陆IP (v20.0 修复)
detect_china_ip() {
    local country
    local final_country="UNKNOWN" # 最终确定的国家
    
    # (v20.0) 多 API 轮询列表
    # API 1: ifconfig.co (经你验证，可以识别 "CN")
    # API 2: ip-api.com (备用)
    # API 3: ip.sb (备用)
    local API_LIST=(
        "https://ifconfig.co/country-iso"
        "http://ip-api.com/json/?fields=countryCode"
        "https://api.ip.sb/country-code"
    )

    print_info "正在检测 IP 地理位置 (多 API 轮询)..."
    
    for api in "${API_LIST[@]}"; do
        print_info "  -> 正在尝试 API: $api"
        
        local result
        result=$(curl -s --max-time 10 "$api")
        
        if [ -z "$result" ]; then
            print_warning "    ... API ($api) 超时或返回空。"
            continue
        fi
        
        # 清理返回结果
        # "CN" (ifconfig, ip.sb)
        # "{"countryCode":"CN"}" (ip-api)
        country=$(echo "$result" | grep -o 'CN' | tr -d ' ')
        
        if [ "$country" = "CN" ]; then
            print_warning "检测到中国大陆 (CN) IP (来自: $api)。"
            print_warning "将切换到手动上传模式。"
            echo "true"
            return 0
        else
            # 记录最后一个非 CN 的结果
            final_country=$(echo "$result" | tr -d ' ' | tr -d '\n' | tr -d '"' | sed 's/countryCode://g' | sed 's/{//g' | sed 's/}//g')
            print_info "    ... API ($api) 返回: $final_country (非CN)。将尝试下一个..."
        fi
    done

    # (v20.0) 循环结束，意味着没有一个 API 返回 "CN"
    
    if [ "$final_country" = "UNKNOWN" ]; then
        # --- 所有 API 都失败了 ---
        print_error "所有 IP 地理位置 API 均检测失败 (网络超时)。"
        print_warning "无法判断是否为中国大陆 VPS。"
        local confirm_cn
        
        while true; do
            read -p "您是否正在中国大陆 (Mainland China) 的 VPS 上运行此脚本? (y/n): " confirm_cn
            case $confirm_cn in
                [Yy]*)
                    print_warning "用户选择: 是中国大陆。将切换到手动上传模式。"
                    echo "true"
                    return 0
                    ;;
                [Nn]*)
                    print_info "用户选择: 非中国大陆。将尝试自动下载。"
                    echo "false"
                    return 0
                    ;;
                *) print_error "请输入 y 或 n" ;;
            esac
        done
    else
        # --- 至少有一个 API 成功了，但都不是 "CN" ---
        print_info "所有 API 均未检测到中国大陆 IP (最后结果: $final_country)。"
        print_info "将从 GitHub 自动下载。"
        echo "false"
        return 0
    fi
}

# --- 核心功能函数 ---

# 1. 安装依赖 (v19.0 恢复 Alpine)
install_dependencies() {
    print_info "正在安装所需依赖..."
    case $OS_TYPE in
    debian)
        export DEBIAN_FRONTEND=noninteractive
        print_info "正在更新 apt 仓库..."
        apt-get update >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            print_error "apt update 失败。请检查网络和软件源。"
            exit 1
        fi
        
        print_info "正在安装核心依赖 (curl, wget, tar, openssl)..."
        if ! apt-get install -y curl wget gzip tar openssl >/dev/null 2>&1; then
            print_error "依赖安装失败 (apt-get install 失败)。"
            exit 1
        fi
        ;;
    alpine)
        print_info "正在更新 apk 仓库..."
        apk update >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            print_error "apk update 失败。请检查网络。"
            exit 1
        fi
        
        print_info "正在安装核心依赖 (curl, wget, tar, openssl, openrc)..."
        if ! apk add --no-cache curl wget tar openssl openrc >/dev/null 2>&1; then
            print_error "依赖安装失败 (apk add 失败)。"
            exit 1
        fi
        ;;
    esac
    print_success "依赖安装完成。"
}

# 2. 安装 Gost (v19.7 重构)
install_gost() {
    if [ -f "${INSTALL_DIR}/gost" ]; then
        print_warning "Gost 似乎已经安装。"
        return
    fi

    install_dependencies
    
    local LATEST_TAG VERSION FILENAME DOWNLOAD_URL LATEST_URL
    local GITHUB_STATUS
    local DOWNLOAD_MODE="auto" # 默认为自动
    
    local FILE_PATH="/tmp/gost-release.tar.gz" 
    local EXTRACT_DIR="/tmp/gost_extract"

    print_info "正在从 GitHub 获取最新版本号 (Web Redirect)..."
    LATEST_URL=$(curl -s -L -o /dev/null -w '%{url_effective}' "https://github.com/${GOST_REPO}/releases/latest")
    GITHUB_STATUS=$?

    # --- 1. 检查 GitHub 是否可达 ---
    if [ $GITHUB_STATUS -ne 0 ] || [ -z "$LATEST_URL" ] || [[ "$LATEST_URL" != *"github.com"* ]]; then
        # (情况 A: GitHub 连接失败)
        print_error "获取最新版本号失败。网络无法连接到 GitHub。"
        print_warning "将切换到手动上传模式。"
        
        # 准备手动上传所需的信息 (我们不知道版本号)
        FILENAME="gost_latest_linux_${ARCH}.tar.gz" # 提示一个示例文件名
        DOWNLOAD_MODE="manual"

    else
        # --- 2. GitHub 可达，解析版本号 ---
        LATEST_TAG=$(echo "$LATEST_URL" | awk -F'/' '{print $NF}')
        if [ -z "$LATEST_TAG" ] || [[ "$LATEST_TAG" == "latest" ]]; then
            print_error "无法从 URL (${LATEST_URL}) 解析版本号。"
            print_warning "将切换到手动上传模式。"
            FILENAME="gost_latest_linux_${ARCH}.tar.gz"
            DOWNLOAD_MODE="manual"
        else
            # --- 3. 版本号解析成功，现在检测 IP (v20.0) ---
            VERSION=${LATEST_TAG#v}
            FILENAME="gost_${VERSION}_linux_${ARCH}.tar.gz"
            DOWNLOAD_URL="https://github.com/${GOST_REPO}/releases/download/${LATEST_TAG}/${FILENAME}"
            
            local is_china
            is_china=$(detect_china_ip) # 调用 v20.0 的多 API 检测

            if [ "$is_china" = "true" ]; then
                # (情况 B: GitHub 可达，但 IP 是 CN)
                print_info "已成功获取最新版本: ${LATEST_TAG}"
                # (v20.0) "检测到中国大陆 IP" 的日志已在 detect_china_ip 中打印
                DOWNLOAD_MODE="manual"
            else
                # (情况 C: GitHub 可达，IP 是海外)
                # (v20.0) "检测到非中国大陆 IP" 的日志已在 detect_china_ip 中打印
                DOWNLOAD_MODE="auto"
            fi
        fi
    fi

    # --- 4. 根据 DOWNLOAD_MODE 执行操作 ---
    
    if [ "$DOWNLOAD_MODE" = "manual" ]; then
        # --- 手动上传分支 (情况 A 和 B) ---
        echo
        print_info "请手动访问 Gost 发布页面:"
        print_info "https://github.com/${GOST_REPO}/releases/latest"
        
        if [ -n "$DOWNLOAD_URL" ]; then
            # (情况 B: 我们知道确切的 URL)
            print_info "-----------------------------------------"
            print_info "请下载以下文件:"
            print_warning "  ${DOWNLOAD_URL}"
            print_info "-----------------------------------------"
        else
            # (情况 A: 我们不知道 URL)
            print_info "请下载适用于 [linux] 和 [${ARCH}] 的 .tar.gz 压缩包。"
            print_info "(例如: ${FILENAME})"
        fi
        
        echo
        print_info "请将下载好的 .tar.gz 文件上传到本VPS的以下路径:"
        print_warning "  ${FILE_PATH}"
        echo
        
        while true; do
            read -p "确认已上传文件? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                if [ -f "$FILE_PATH" ]; then
                    print_success "文件已找到。"
                    break
                else
                    print_error "在 ${FILE_PATH} 未找到文件。请检查路径和文件名。"
                fi
            elif [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
                print_error "安装已取消。"
                return
            fi
        done
        
    else
        # --- 自动下载分支 (情况 C) ---
        print_info "正在下载 Gost ${LATEST_TAG} (${FILENAME})..."
        wget -q --show-progress -O "${FILE_PATH}" "${DOWNLOAD_URL}"
        if [ $? -ne 0 ]; then
            print_error "下载失败。"
            rm -f "${FILE_PATH}"
            return
        fi
    fi
    
    # --- 5. 解压和安装 (公共逻辑) ---
    
    if [ ! -f "${FILE_PATH}" ]; then
        print_error "未找到 Gost 压缩包 (${FILE_PATH})。安装中止。"
        return
    fi

    print_info "正在安装 Gost..."
    mkdir -p "${EXTRACT_DIR}"
    
    if ! tar -xzf "${FILE_PATH}" -C "${EXTRACT_DIR}"; then
        print_error "解压失败。请确保 'tar' 已安装。"
        rm -f "${FILE_PATH}"
        rm -rf "${EXTRACT_DIR}"
        return
    fi
    
    if [ ! -f "${EXTRACT_DIR}/gost" ]; then
        print_error "在解压文件中未找到 'gost' 可执行文件。"
        rm -f "${FILE_PATH}"
        rm -rf "${EXTRACT_DIR}"
        return
    fi
    
    mv "${EXTRACT_DIR}/gost" "${INSTALL_DIR}/gost"
    chmod +x "${INSTALL_DIR}/gost"
    
    # 清理临时文件
    rm -f "${FILE_PATH}"
    rm -rf "${EXTRACT_DIR}"
    
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"
    
    setup_service
    
    print_success "Gost 安装完成! (版本: $(${INSTALL_DIR}/gost -V))"
}

# 3. 卸载 Gost (v19.0 恢复 OpenRC)
uninstall_gost() {
    print_warning "此操作将停止 Gost 服务并删除所有相关文件！"
    print_warning "(包括二进制文件, 配置文件, 服务文件)"
    read -p "确定要卸载吗? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "卸载已取消。"
        return
    fi
    
    stop_gost
    
    # 移除服务文件
    case $INIT_SYSTEM in
    systemd)
        if [ -f "${SERVICE_FILE_SYSTEMD}" ]; then
            rm -f "${SERVICE_FILE_SYSTEMD}"
            systemctl daemon-reload
        fi
        ;;
    openrc)
        if [ -f "${SERVICE_FILE_OPENRC}" ]; then
            rm -f "${SERVICE_FILE_OPENRC}"
        fi
        ;;
    direct)
        ;;
    esac
    
    rm -f "${INSTALL_DIR}/gost"
    rm -rf "${CONFIG_DIR}"
    rm -f "${LOG_FILE}"
    rm -f "${PID_FILE}"
    
    print_success "Gost 已完全卸载。"
    
    read -p "是否删除此管理脚本? (y/n): " delete_script
    if [[ "$delete_script" == "y" || "$delete_script" == "Y" ]]; then
        print_info "正在删除脚本: ${SCRIPT_FILE_PATH}"
        rm -f "${SCRIPT_FILE_PATH}"
        exit 0
    fi
}

# 4. 设置服务 (v19.3 修复 OpenRC)
setup_service() {
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"

    # 从 services.conf 读取所有参数
    local ARGS
    ARGS=$(cat "${CONFIG_FILE}" | xargs)

    # (v19.1 修复)
    # 仅 systemd 模式在 ARGS 为空时会启动失败 (looping)
    if [ "$INIT_SYSTEM" = "systemd" ] && [ -z "$ARGS" ]; then
        print_warning "配置文件 ${CONFIG_FILE} 为空。"
        print_info "正在停止并禁用 systemd 服务 (gost)..."
        
        if systemctl is-active --quiet gost; then
            systemctl stop gost
        fi
        
        systemctl disable gost >/dev/null 2>&1
        
        if [ -f "${SERVICE_FILE_SYSTEMD}" ]; then
            rm -f "${SERVICE_FILE_SYSTEMD}"
        fi
        
        systemctl daemon-reload
        print_info "Systemd 服务 (gost) 已停止并移除。"
        return
    fi
    
    print_info "正在根据 ${CONFIG_FILE} 重新生成服务文件..."
    
    case $INIT_SYSTEM in
    systemd)
        # 此时 ARGS 肯定不为空
        cat > "${SERVICE_FILE_SYSTEMD}" <<EOF
[Unit]
Description=Gost Dynamic Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/gost ${ARGS}
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        print_info "Systemd 服务已更新。"
        ;;
    openrc)
        cat > "${SERVICE_FILE_OPENRC}" <<EOF
#!/sbin/openrc-run

description="Gost Dynamic Proxy Service"

command="${INSTALL_DIR}/gost"
command_args="${ARGS}"
pidfile="${PID_FILE}"

depend() {
    need net
    after network
}

start() {
    ebegin "Starting Gost"
    if [ -z "\$command_args" ]; then
        einfo "No services configured in ${CONFIG_FILE}. Gost not started."
        return 0
    fi
    
    # (v19.3 修复)
    # 将 --stdout/--stderr 移到 -- 之前
    start-stop-daemon --start --background \
        --make-pidfile --pidfile \$pidfile \
        --stdout "${LOG_FILE}" --stderr "${LOG_FILE}" \
        --exec \$command -- \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping Gost"
    start-stop-daemon --stop --pidfile \$pidfile --quiet
    if [ \$? -eq 0 ]; then
        rm -f \$pidfile
    fi
    eend \$?
}
EOF
        chmod +x "${SERVICE_FILE_OPENRC}"
        print_info "OpenRC 服务已更新。"
        ;;
    direct)
        print_info "'direct' 模式不需要设置服务文件。"
        print_info "将使用 'start_gost' 和 'stop_gost' 手动管理。"
        ;;
    esac
}

# 5. 启动 Gost (v19.0 恢复 OpenRC)
start_gost() {
    if ! [ -f "${INSTALL_DIR}/gost" ]; then
        print_error "Gost 未安装。"
        return
    fi
    
    print_info "正在启动 Gost..."
    
    case $INIT_SYSTEM in
    systemd)
        systemctl enable gost >/dev/null 2>&1
        systemctl start gost
        ;;
    openrc)
        rc-update add gost default >/dev/null 2>&1
        rc-service gost start
        ;;
    direct)
        if check_service_status; then
            print_warning "Gost 已经在运行 (PID: $(cat "$PID_FILE"))."
            return
        fi
        
        local ARGS
        ARGS=$(cat "${CONFIG_FILE}" | xargs)
        
        if [ -z "$ARGS" ]; then
            print_info "No services configured in ${CONFIG_FILE}. Gost not started."
            return
        fi
        
        nohup "${INSTALL_DIR}/gost" ${ARGS} > "${LOG_FILE}" 2>&1 &
        echo $! > "${PID_FILE}"
        sleep 1
        
        if check_service_status; then
            print_success "Gost (direct) 已启动 (PID: $(cat "$PID_FILE"))."
        else
            print_error "Gost (direct) 启动失败。请查看日志: ${LOG_FILE}"
        fi
        ;;
    esac
    
    sleep 1
    view_status
}

# 6. 停止 Gost (v19.0 恢复 OpenRC)
stop_gost() {
    print_info "正在停止 Gost..."
    case $INIT_SYSTEM in
    systemd)
        systemctl disable gost >/dev/null 2>&1
        systemctl stop gost
        ;;
    openrc)
        rc-update del gost default >/dev/null 2>&1
        rc-service gost stop
        ;;
    direct)
        if [ -f "$PID_FILE" ]; then
            local pid
            pid=$(cat "$PID_FILE")
            if kill -0 "$pid" >/dev/null 2>&1; then
                kill "$pid"
                rm -f "$PID_FILE"
                print_success "Gost (direct) 已停止 (PID: $pid)."
            else
                print_warning "PID 文件存在，但进程 ($pid) 未运行。正在清理PID文件。"
                rm -f "$PID_FILE"
            fi
        else
            print_warning "GGost (direct) 未在运行。"
        fi
        ;;
    esac
}

# 7. 重启 Gost (v19.0 恢复 OpenRC)
restart_gost() {
    if ! [ -f "${INSTALL_DIR}/gost" ]; then
        print_error "Gost 未安装。"
        return
    fi
    
    print_info "正在重启 Gost (将重新加载配置)..."
    
    case $INIT_SYSTEM in
    systemd)
        setup_service # 重新生成 (或移除) systemd service file
        
        # (v19.1 修复)
        # 检查 setup_service 是否因为配置为空而移除了服务文件
        if [ ! -f "${SERVICE_FILE_SYSTEMD}" ]; then
            print_info "Gost 配置为空，服务已停止并移除。"
        else
            systemctl restart gost
        fi
        ;;
    openrc)
        setup_service # 重新生成 openrc init.d file
        rc-service gost restart
        ;;
    direct)
        stop_gost
        sleep 1
        start_gost
        ;;
    esac
}

# 8. 查看状态 (v19.0 恢复 OpenRC)
view_status() {
    echo "--- Gost 运行状态 ---"
    case $INIT_SYSTEM in
    systemd)
        systemctl status gost --no-pager
        ;;
    openrc)
        rc-service gost status
        ;;
    direct)
        if check_service_status; then
            print_success "Gost (direct) 正在运行 (PID: $(cat "$PID_FILE"))."
        else
            print_error "Gost (direct) 未运行。"
        fi
        ;;
    esac
    echo "-----------------------"
}

# 9. 查看日志 (v19.2 修复 OpenRC/Direct)
view_logs() {
    print_info "正在实时查看日志 (按 Ctrl+C 退出)..."
    case $INIT_SYSTEM in
    systemd)
        journalctl -u gost -f --no-pager
        ;;
    openrc | direct)
        # (v19.2 修复) 
        # 无论文件是否存在，都尝试创建它，以确保 tail -f 可以 "watch"
        if [ ! -f "$LOG_FILE" ]; then
            print_warning "日志文件 $LOG_FILE 不存在。"
            print_info "正在创建空日志文件以供 tail 监视..."
            touch "$LOG_FILE"
            if [ $? -ne 0 ]; then
                print_error "无法创建日志文件 $LOG_FILE。请检查 /var/log/ 目录权限。"
                # 既然 tail 也会失败，这里需要 pause
                pause
                return
            fi
        fi
        
        # tail -f 会保持运行并监视文件
        tail -f "$LOG_FILE"
        ;;
    esac
}

# --- 配置菜单 ---

# 辅助函数: 检查并初始化配置文件
init_config_file() {
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"
}

# (v18.0)
ask_for_restart() {
    print_warning "配置已更改，需要重启 Gost 才能生效。"
    
    print_info "--- [诊断] 重启前检查 /etc/gost 目录 ---"
    ls -l "${CONFIG_DIR}"
    echo "------------------------------------------------"
    
    read -p "是否立即重启 Gost? (y/n): " confirm_restart
    if [[ "$confirm_restart" == "y" || "$confirm_restart" == "Y" ]]; then
        # (v19.1) 重启 = 重建服务 + 重启
        restart_gost
        
        print_info "正在执行重启后健康检查 (等待 2 秒)..."
        sleep 2
        
        # (v19.1 修复)
        # 检查配置文件是否为空。如果为空，"未运行" 是正确状态。
        if [ ! -s "${CONFIG_FILE}" ]; then
            if check_service_status; then
                # 这不应该发生，但以防万一
                print_error "Gost 配置文件为空，但服务仍在运行。这可能是一个错误。"
            else
                print_success "Gost 配置文件为空，服务已按预期停止。"
            fi
        else
            # 配置文件不为空，检查服务是否在运行
            if check_service_status; then
                print_success "Gost 已成功重启并运行正常。"
            else
                print_error "Gost 重启后似乎运行失败！"
                print_warning "请立即使用主菜单的 '7. 查看 Gost 日志' 功能检查具体错误。"
                print_warning "您的配置更改已保存。"
            fi
        fi
    else
        print_info "配置已保存。请稍后记得从主菜单重启。"
    fi
}

# (v15.0) 配置 - SOCKS5 代理
config_socks5_auth() {
    local port user pass
    read -p "请输入 SOCKS5 监听端口 : " port
    read -p "请输入用户名: " user
    read -p "请输入密码: " pass
    echo
    
    if [ -z "$port" ]; then
        print_error "端口不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${port}) 未被其他服务使用。"
    init_config_file
    
    local CMD_LINE="-L 'socks5://${user}:${pass}@:${port}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "SOCKS5 服务 (:${port}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - TCP 转发 (中转)
config_tcp_relay() {
    local lport raddr
    read -p "请输入本地监听端口 (TCP) : " lport
    read -p "请输入远程目标地址 (TCP) (例如：8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    init_config_file

    local CMD_LINE="-L 'tcp://:${lport}/${raddr}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "TCP 转发 (:${lport} -> ${raddr}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - UDP 转发 (中转)
config_udp_relay() {
    local lport raddr
    read -p "请输入本地监听端口 (UDP) : " lport
    read -p "请输入远程目标地址 (UDP) (例如：8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    print_warning "请注意：你必须在VPS的防火墙 (如 ufw, firewalld 或云服务商安全组) 中放行 ${lport} 的 UDP 端口。"
    init_config_file
    
    local CMD_LINE="-L 'udp://:${lport}/${raddr}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "UDP 转发 (:${lport} -> ${raddr}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - TCP/UDP 联合转发
config_tcp_udp_relay() {
    local lport raddr
    read -p "请输入本地监听端口 (TCP/UDP) : " lport
    read -p "请输入远程目标地址 (TCP/UDP) (例如：8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    print_warning "请注意：你必须在VPS的防火墙中同时放行 ${lport} 的 TCP 和 UDP 端口。"
    init_config_file
    
    local CMD_LINE_TCP="-L 'tcp://:${lport}/${raddr}'"
    local CMD_LINE_UDP="-L 'udp://:${lport}/${raddr}'"
    
    echo "${CMD_LINE_TCP}" >> "${CONFIG_FILE}"
    echo "${CMD_LINE_UDP}" >> "${CONFIG_FILE}"

    print_success "TCP/UDP 联合转发 (:${lport} -> ${raddr}) 已添加。"
    ask_for_restart
}

# (v15.0) 配置 - SOCKS5 中转 (加密到下一跳 TLS)
config_socks5_chain_tls() {
    local lport user pass raddr
    read -p "请输入 SOCKS5 监听端口 : " lport
    read -p "请输入 SOCKS5 用户名 : " user
    read -p "请输入 SOCKS5 密码 : " pass
    read -p "请输入远程[海外VPS]的 TLS 目标地址 (例如：8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "监听端口和远程地址不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    print_warning "重要: 命令行模式将自动添加 'insecure=true' 来跳过自签名证书验证。"
    
    local CMD_LINE="-L 'socks5://${user}:${pass}@:${lport}' -F 'relay+tls://${raddr}?insecure=true'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "SOCKS5 链式转发 (:${lport} -> tls://${raddr}) 已添加。"
    ask_for_restart
}

# (v17.1) 配置 - TLS 隧道服务端 (SOCKS5 落地)
config_tls_socks_listener() {
    local lport
    read -p "请输入 TLS 监听端口 (例如：8.8.8.8:53): " lport
    
    if [ -z "$lport" ]; then
        print_error "端口不能为空。"
        return
    fi
    
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    
    local cert_path="${CONFIG_DIR}/cert.pem"
    local key_path="${CONFIG_DIR}/key.pem"
    
    print_info "此服务将作为 TLS 终端，接收来自中转 VPS 的加密流量。"
    print_warning "请确保在防火墙 (安全组) 中放行 ${lport} 的 TCP 端口。"

    if [ ! -f "${cert_path}" ] || [ ! -f "${key_path}" ]; then
        print_warning "未找到 ${cert_path} 和 ${key_path}。"
        print_info "正在生成自签名证书 (有效期10年)..."
        
        if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "${key_path}" -out "${cert_path}" \
                -subj "/C=US/ST=CA/L=MyCity/O=MyOrg/OU=MyUnit/CN=gost.local"; then
            print_error "OpenSSL 命令执行失败。请检查 'openssl' 是否已安装以及上面的输出。"
            return
        fi

        if [ ! -f "${cert_path}" ] || [ ! -f "${key_path}" ]; then
            print_error "证书文件生成失败！"
            print_warning "OpenSSL 命令似乎已运行，但未在 ${CONFIG_DIR} 中创建 cert.pem/key.pem。"
            print_warning "请检查 ${CONFIG_DIR} 目录的权限。"
            return
        fi
        
        print_success "自签名证书生成完毕。"

        print_info "正在强制文件系统同步 (sync)..."
        sync
        sleep 1
        print_info "同步完成。"

        print_info "--- [诊断] 证书生成后检查 /etc/gost 目录 ---"
        ls -l "${CONFIG_DIR}"
        echo "------------------------------------------------"
        
    else
        print_info "检测到现有的 cert.pem/key.pem, 将直接使用。"
    fi

    init_config_file
    
    local CMD_LINE="-L 'relay+tls://:${lport}?cert=${cert_path}&key=${key_path}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "TLS 隧道服务端 (:${lport}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}


# (v16.3) 配置 - 删除一个指定配置
delete_specific_config() {
    init_config_file
    
    if [ ! -s "${CONFIG_FILE}" ]; then
        print_error "配置文件中没有找到可删除的服务。"
        return
    fi
    
    mapfile -t SERVICES < "${CONFIG_FILE}"
    
    print_info "--- 当前配置的服务列表 ---"
    
    PS3="请选择要删除的配置 (输入 0 取消): "
    select SERVICE_TO_DELETE in "${SERVICES[@]}"; do
        if [[ "$REPLY" == "0" ]]; then
            print_info "操作已取消。"
            break
        fi

        if [ -n "$SERVICE_TO_DELETE" ]; then
            read -p "你确定要删除服务 '$SERVICE_TO_DELETE' 吗? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                
                # 使用 grep 精确匹配并排除行
                grep -v -F -x -e "${SERVICE_TO_DELETE}" "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
                local grep_status=$?
                
                if [ $grep_status -eq 2 ]; then
                    print_error "Grep 命令执行失败 (语法或文件错误)。配置未更改。"
                    rm -f "${CONFIG_FILE}.tmp"
                    break
                fi
                
                # 验证操作是否成功 (临时文件存在且行数减少，或者临时文件为空)
                if [ -f "${CONFIG_FILE}.tmp" ] && \
                   ( [ ! -s "${CONFIG_FILE}.tmp" ] || \
                     [ $(wc -l < "${CONFIG_FILE}.tmp") -lt $(wc -l < "${CONFIG_FILE}") ] ); then
                   mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                   print_success "已删除 '$SERVICE_TO_DELETE'."
                else
                   print_error "删除操作似乎未成功执行 (临时文件异常)。配置未更改。"
                   rm -f "${CONFIG_File}.tmp"
                fi

                ask_for_restart
                break
            else
                print_info "已取消删除。"
                break
            fi
        else
            print_error "无效选项 $REPLY"
        fi
    done
    
    # 恢复默认的 PS3 提示符
    PS3="#? "
}


# 配置子菜单
manage_config() {
    while true; do
        clear
        echo "--- Gost 功能配置菜单  ---"
        echo -e "配置文件路径: ${YELLOW}${CONFIG_FILE}${NC}"
        echo
        print_warning "重要: 添加多个服务时, 请确保它们使用不同的监听端口!"
        echo
        echo "--- 添加新服务 (基础) ---"
        echo " 1. 添加: SOCKS5 代理 (带认证)"
        echo " 2. 添加: TCP 转发/中转 (仅TCP)"
        echo " 3. 添加: UDP 转发/中转 (仅UDP)"
        echo " 4. 添加: TCP/UDP 联合转发"
        echo
        echo "--- 添加新服务 (TLS 隧道) ---"
        echo -e " 5. ${GREEN}添加: SOCKS5 中转 (-> TLS)${NC} (国内VPS)"
        echo -e " 6. ${GREEN}添加: TLS 隧道服务端${NC} (海外VPS)"
        echo
        echo "--- 管理配置 ---"
        echo -e " 7. ${YELLOW}删除一个指定配置${NC}"
        echo
        echo " 0. 返回主菜单"
        echo
        read -p "请输入选项 [0-7]: " choice
        
        case $choice in
        1)
            config_socks5_auth
            pause
            ;;
        2)
            config_tcp_relay
            pause
            ;;
        3)
            config_udp_relay
            pause
            ;;
        4) 
            config_tcp_udp_relay
            pause
            ;;
        5) 
            config_socks5_chain_tls
            pause
            ;;
        6) 
            config_tls_socks_listener
            pause
            ;;
        7) 
            delete_specific_config
            pause
            ;;
        0)
            break
            ;;
        *)
            print_error "无效选项。"
            sleep 1
            ;;
        esac
    done
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo "========================================="
        echo "         Gost 转发面板管理脚本              "
        echo "========================================="
        echo -e " 系统: ${YELLOW}$OS_TYPE${NC} | 架构: ${YELLOW}$ARCH${NC} | 管理: ${YELLOW}$INIT_SYSTEM${NC}"
        echo "-----------------------------------------"
        echo " 1. 安装 Gost"
        echo " 2. 卸载 Gost"
        echo "-----------------------------------------"
        echo " 3. 启动 Gost"
        echo " 4. 停止 Gost"
        echo " 5. 重启 Gost"
        echo "-----------------------------------------"
        echo " 6. 查看 Gost 状态"
        echo " 7. 查看 Gost 日志"
        echo " 8. Gost 服务管理"
        echo "-----------------------------------------"
        echo " 0. 退出脚本"
        echo "========================================="
        echo
        read -p "请输入选项 [0-8]: " choice
        
        case $choice in
        1)
            install_gost
            pause
            ;;
        2)
            uninstall_gost
            pause
            ;;
        3)
            start_gost
            pause
            ;;
        4)
            stop_gost
            pause
            ;;
        5)
            restart_gost
            print_info "Gost 已尝试重启，请使用 '6. 查看状态' 确认。"
            pause
            ;;
        6)
            view_status
            pause
            ;;
        7)
            view_logs
            ;;
        8)
            manage_config
            ;;
        0)
            print_info "感谢使用！"
            exit 0
            ;;
        *)
            print_error "无效选项。"
            sleep 1
            ;;
        esac
    done
}

# --- 脚本入口 ---

check_root
detect_os
detect_arch

# (v19.0) 恢复 Alpine 专用的 Bash 检查
check_bash_dependency

# 必须在 bash 检查后
detect_init_system

# 执行核心依赖预检查
check_core_dependencies

main_menu