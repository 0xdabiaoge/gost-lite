#!/bin/bash

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
# (v15.0) 核心配置文件
CONFIG_FILE="${CONFIG_DIR}/services.conf"

# (v16.0) 为 Direct 模式重新启用
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

# (v16.0) 重构: 恢复 OpenRC 和 Direct 的检查
check_service_status() {
    case $INIT_SYSTEM in
    systemd)
        if systemctl is-active --quiet gost; then
            return 0 # Success
        else
            return 1 # Failure
        fi
        ;;
    openrc)
        if rc-service -q status gost; then
            return 0
        else
            return 1
        fi
        ;;
    direct)
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

# (P5) 辅助函数: 核心依赖预检查 (v15 简化)
check_core_dependencies() {
    local missing_deps=()
    # (v16.1) 增加 openssl 检查
    for cmd in curl tar openssl grep mv wc; do # (v16.5) 添加 grep, mv, wc
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

# 1. 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" = "debian" ] || [ "$ID_LIKE" = "debian" ]; then
            OS_TYPE="debian"
        elif [ "$ID" = "alpine" ]; then
            OS_TYPE="alpine"
        else
            print_error "不支持的操作系统: $ID"
            exit 1
        fi
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

# 3. 检测初始化系统 (v16.0 恢复兼容)
detect_init_system() {
    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="direct"
        print_warning "未检测到 systemd 或 OpenRC。将使用 direct 进程管理模式。"
        print_warning "在此模式下，gost 不会自动开机启动。"
    fi
    print_info "检测到初始化系统: $INIT_SYSTEM"
}

# 4. 检测中国大陆IP (P6 - 优化)
detect_china_ip() {
    local country
    
    country=$(curl -s --max-time 10 https://api.ip.sb/geoip | grep -o '"country_code":"[^"]*"' | cut -d':' -f2 | tr -d '"')
    
    if [ -z "$country" ]; then
        print_warning "IP detection (ip.sb) failed, trying fallback (ipinfo.io)..."
        country=$(curl -s --max-time 10 https://ipinfo.io/country | tr -d '\n')
    fi
    
    # (P6) 优化: 当两个 API 都失败时，主动询问用户
    if [ -z "$country" ]; then
        print_error "自动检测 IP 地理位置失败 (网络超时)。"
        print_warning "无法判断是否为中国大陆 VPS。"
        local confirm_cn
        while true; do
            read -p "您是否正在中国大陆的 VPS 上运行此脚本? (y/n): " confirm_cn
            case $confirm_cn in
                [Yy]*) country="CN"; break ;;
                [Nn]*) country="US"; break ;; # 假定为海外
                *) print_error "请输入 y 或 n" ;;
            esac
        done
    fi
    
    if [ "$country" = "CN" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# --- 核心功能函数 ---

# 1. 安装依赖 (v16.1 增加 openssl)
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
        
        # (v16.5) 添加 grep, coreutils(mv, wc)
        print_info "正在安装核心依赖 (curl, wget, tar, openssl, grep, coreutils)..."
        if ! apt-get install -y curl wget gzip tar openssl grep coreutils >/dev/null 2>&1; then
            print_error "依赖安装失败 (apt-get install 失败)。"
            exit 1
        fi
        ;;
    alpine)
        print_info "正在更新 apk 仓库..."
        apk update
        if [ $? -ne 0 ]; then
            print_error "apk update 失败。请检查网络和 DNS 设置。"
            exit 1
        fi
        
        # (v16.5) 添加 grep
        print_info "正在安装核心依赖 (bash, curl, wget, coreutils, tar, openssl, grep)..."
        if ! apk add bash curl wget gzip coreutils tar openssl grep; then
            print_error "依赖安装失败 (apk add 失败)。"
            print_warning "请检查上面的 'apk add' 命令输出以了解具体原因。"
            exit 1
        fi
        ;;
    esac
    print_success "依赖安装完成。"
}

# 2. 安装 Gost (v15.0 变更)
install_gost() {
    if [ -f "${INSTALL_DIR}/gost" ]; then
        print_warning "Gost 似乎已经安装。"
        return
    fi

    install_dependencies
    
    local is_china
    is_china=$(detect_china_ip)
    
    local LATEST_TAG VERSION DOWNLOAD_URL FILENAME
    local FILE_PATH="/tmp/gost-release.tar.gz" 
    local EXTRACT_DIR="/tmp/gost_extract"

    if [ "$is_china" = "true" ]; then
        # 中国VPS处理逻辑
        print_warning "检测到中国大陆IP。由于网络限制，无法自动从 GitHub 下载。"
        print_info "请手动访问 Gost 发布页面: https://github.com/${GOST_REPO}/releases/latest"
        
        print_warning "无法自动获取最新版本号。请自行在发布页面查找。"
        print_info "你需要下载适用于 [linux] 和 [${ARCH}] 架构的 .tar.gz 压缩包。"
        print_info "例如: gost_3.2.5_linux_${ARCH}.tar.gz"
        
        echo
        print_info "请将下载好的 .tar.gz 文件上传到本VPS的以下路径:"
        print_warning "${FILE_PATH}"
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
        # 海外VPS处理逻辑
        
        print_info "正在从 GitHub 获取最新版本号 (Web Redirect)..."
        local LATEST_URL
        LATEST_URL=$(curl -s -L -o /dev/null -w '%{url_effective}' "https://github.com/${GOST_REPO}/releases/latest")
        
        if [ $? -ne 0 ] || [ -z "$LATEST_URL" ] || [[ "$LATEST_URL" != *"github.com"* ]]; then
            print_error "获取最新版本号失败。请检查网络连接。"
            return
        fi
        
        LATEST_TAG=$(echo "$LATEST_URL" | awk -F'/' '{print $NF}')
        
        if [ -z "$LATEST_TAG" ] || [[ "$LATEST_TAG" == "latest" ]]; then
            print_error "无法从 URL (${LATEST_URL}) 解析版本号。"
            return
        fi
        
        VERSION=${LATEST_TAG#v}
        FILENAME="gost_${VERSION}_linux_${ARCH}.tar.gz"
        DOWNLOAD_URL="https://github.com/${GOST_REPO}/releases/download/${LATEST_TAG}/${FILENAME}"
        
        print_info "正在下载 Gost ${LATEST_TAG} (${FILENAME})..."
        wget -q --show-progress -O "${FILE_PATH}" "${DOWNLOAD_URL}"
        if [ $? -ne 0 ]; then
            print_error "下载失败。"
            rm -f "${FILE_PATH}"
            return
        fi
    fi
    
    # 解压和安装
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
    
    # (v15.0) 创建配置目录和空配置文件
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"
    
    # (v15.0) 设置服务
    setup_service
    
    # (v14.1 修复) 修正为大写 -V
    print_success "Gost 安装完成! (版本: $(${INSTALL_DIR}/gost -V))"
}

# 3. 卸载 Gost (v16.2 文本清理)
uninstall_gost() {
    print_warning "此操作将停止 Gost 服务并删除所有相关文件！"
    print_warning "(包括二进制文件, 配置文件)"
    read -p "确定要卸载吗? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "卸载已取消。"
        return
    fi
    
    stop_gost
    
    # 移除服务文件
    case $INIT_SYSTEM in
    systemd)
        rm -f "${SERVICE_FILE_SYSTEMD}"
        systemctl daemon-reload
        ;;
    openrc)
        rm -f "${SERVICE_FILE_OPENRC}"
        ;;
    direct)
        ;;
    esac
    
    # (v16.0) 删除二进制文件、配置、日志和PID
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

# 4. 设置服务 (v16.0 重构, 核心)
setup_service() {
    # 确保配置文件存在
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"

    # 从 services.conf 读取所有参数
    # xargs 将换行符转换为空格，使其成为一行命令
    local ARGS
    ARGS=$(cat "${CONFIG_FILE}" | xargs)

    print_info "正在根据 ${CONFIG_FILE} 重新生成服务文件..."
    
    case $INIT_SYSTEM in
    systemd)
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

name="gost"
description="Gost Dynamic Proxy Service"

command="${INSTALL_DIR}/gost"
command_args="${ARGS}"

# (v16.0) OpenRC 将在后台管理
command_background="yes" 
pidfile="${PID_FILE}"

depend() {
    need net
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

# 5. 启动 Gost (v16.4 修复 Direct)
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
        
        # (v16.0) 从配置文件读取参数
        local ARGS
        ARGS=$(cat "${CONFIG_FILE}" | xargs)
        
        # [v16.4 修复] 检查参数是否为空
        if [ -z "$ARGS" ]; then
            print_info "没有配置任何服务 (${CONFIG_FILE} 为空)。Gost 未启动。"
            return
        fi
        
        nohup "${INSTALL_DIR}/gost" ${ARGS} > "${LOG_FILE}" 2>&1 &
        echo $! > "${PID_FILE}"
        sleep 1
        
        if check_service_status; then
            print_success "Gost (direct) 已启动 (PID: $(cat "$PID_FILE"))."
        else
            print_error "Gost (direct) 启动失败。请查看日志: ${LOG_FILE}"
            # 不要删除 PID 文件，因为进程可能短暂存在过
        fi
        ;;
    esac
    
    if [ "$INIT_SYSTEM" != "direct" ]; then
        view_status
    fi
}

# 6. 停止 Gost (v16.0 重构)
stop_gost() {
    if ! [ -f "${INSTALL_DIR}/gost" ] && ! [ -f "$PID_FILE" ] && ! command -v systemctl >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
        print_error "Gost 未安装或未在运行。"
        return
    fi

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
            print_warning "Gost (direct) 未在运行。"
        fi
        ;;
    esac
}

# 7. 重启 Gost (v16.0 重构)
restart_gost() {
    if ! [ -f "${INSTALL_DIR}/gost" ]; then
        print_error "Gost 未安装。"
        return
    fi
    
    print_info "正在重启 Gost (将重新加载配置)..."
    
    case $INIT_SYSTEM in
    systemd)
        # 核心: 先重载配置, 再重启
        setup_service
        systemctl restart gost
        ;;
    openrc)
        # 核心: 先重载配置, 再重启
        setup_service
        rc-service gost restart
        ;;
    direct)
        stop_gost
        sleep 1
        start_gost
        ;;
    esac
}

# 8. 查看状态 (v16.0 重构)
view_status() {
    if ! [ -f "${INSTALL_DIR}/gost" ]; then
        print_error "Gost 未安装。"
        return
    fi
    
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

# 9. 查看日志 (v16.0 重构)
view_logs() {
    print_info "正在实时查看日志 (按 Ctrl+C 退出)..."
    case $INIT_SYSTEM in
    systemd)
        journalctl -u gost -f --no-pager
        ;;
    openrc | direct)
        if [ -f "$LOG_FILE" ]; then
            tail -f "$LOG_FILE"
        else
            print_error "日志文件不存在: $LOG_FILE"
        fi
        ;;
    esac
}

# --- 配置菜单 ---

# 辅助函数: 检查并初始化配置文件
init_config_file() {
    mkdir -p "${CONFIG_DIR}"
    touch "${CONFIG_FILE}"
}

# (v16.2 文本清理)
ask_for_restart() {
    print_warning "配置已更改，需要重启 Gost 才能生效。"
    read -p "是否立即重启 Gost? (y/n): " confirm_restart
    if [[ "$confirm_restart" == "y" || "$confirm_restart" == "Y" ]]; then
        # (v16.0) 重启 = 重建服务 + 重启
        restart_gost
        
        # (P4) 执行重启后健康检查
        print_info "正在执行重启后健康检查 (等待 2 秒)..."
        sleep 2
        
        # (v16.4) 针对 direct 模式空配置的特殊处理
        if [ "$INIT_SYSTEM" = "direct" ] && [ ! -s "$CONFIG_FILE" ]; then
            print_info "所有服务已删除。Gost 未启动。"
        elif check_service_status; then
            print_success "Gost 已成功重启并运行正常。"
        else
            print_error "Gost 重启后似乎运行失败！"
            print_warning "Gost 启动失败。可能原因:"
            print_warning "  1. 端口冲突 (例如, 两个服务监听同一端口)。"
            print_warning "  2. 配置语法错误 (虽然命令行模式下少见)。"
            print_warning "请立即使用主菜单的 '7. 查看 Gost 日志' 功能检查具体错误。"
            print_warning "您的配置更改已保存。"
        fi
    else
        print_info "配置已保存。请稍后记得从主菜单重启。"
    fi
}

# (v15.0) 配置 - SOCKS5 代理
config_socks5_auth() {
    # (v16.2) 移除备份
    
    local port user pass
    read -p "请输入 SOCKS5 监听端口 : " port
    read -p "请输入用户名: " user
    read -p "请输入密码: " pass
    echo
    
    if [ -z "$port" ]; then
        print_error "端口不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${port}) 未被其他服务使用。"

    init_config_file
    
    # v15.0: 写入命令行
    local CMD_LINE="-L 'socks5://${user}:${pass}@:${port}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "SOCKS5 服务 (:${port}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - TCP 转发 (中转)
config_tcp_relay() {
    # (v16.2) 移除备份
    
    local lport raddr
    read -p "请输入本地监听端口 (TCP) : " lport
    read -p "请输入远程目标地址 (TCP) (例如,8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    
    init_config_file

    # v15.0: 写入命令行
    local CMD_LINE="-L 'tcp://:${lport}/${raddr}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "TCP 转发 (:${lport} -> ${raddr}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - UDP 转发 (中转)
config_udp_relay() {
    # (v16.2) 移除备份
    
    local lport raddr
    read -p "请输入本地监听端口 (UDP) : " lport
    read -p "请输入远程目标地址 (UDP) (例如,8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    print_warning "请注意：你必须在VPS的防火墙 (如 ufw, firewalld 或云服务商安全组) 中放行 ${lport} 的 UDP 端口。"

    init_config_file
    
    # v15.0: 写入命令行
    local CMD_LINE="-L 'udp://:${lport}/${raddr}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "UDP 转发 (:${lport} -> ${raddr}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}

# (v15.0) 配置 - TCP/UDP 联合转发
config_tcp_udp_relay() {
    # (v16.2) 移除备份
    
    local lport raddr
    read -p "请输入本地监听端口 (TCP/UDP) : " lport
    read -p "请输入远程目标地址 (TCP/UDP) (例如,8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "本地端口或远程地址不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    print_warning "请注意：你必须在VPS的防火墙中同时放行 ${lport} 的 TCP 和 UDP 端口。"
    init_config_file
    
    # v15.0: 写入命令行 (两条)
    local CMD_LINE_TCP="-L 'tcp://:${lport}/${raddr}'"
    local CMD_LINE_UDP="-L 'udp://:${lport}/${raddr}'"
    
    echo "${CMD_LINE_TCP}" >> "${CONFIG_FILE}"
    echo "${CMD_LINE_UDP}" >> "${CONFIG_FILE}"

    print_success "TCP/UDP 联合转发 (:${lport} -> ${raddr}) 已添加。"
    ask_for_restart
}

# (v15.0) 配置 - SOCKS5 中转 (加密到下一跳 TLS)
config_socks5_chain_tls() {
    # (v16.2) 移除备份
    
    local lport user pass raddr
    read -p "请输入 SOCKS5 监听端口 : " lport
    read -p "请输入 SOCKS5 用户名 : " user
    read -p "请输入 SOCKS5 密码 : " pass
    read -p "请输入远程[海外VPS]的 TLS 目标地址 (例如,8.8.8.8:53): " raddr
    
    if [ -z "$lport" ] || [ -z "$raddr" ]; then
        print_error "监听端口和远程地址不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"

    # v15.0: 写入命令行 (v2 风格, 来自 Gost转发教程.txt)
    print_warning "重要: 命令行模式将自动添加 'insecure=true' 来跳过自签名证书验证。"
    
    local CMD_LINE="-L 'socks5://${user}:${pass}@:${lport}' -F 'relay+tls://${raddr}?insecure=true'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "SOCKS5 链式转发 (:${lport} -> tls://${raddr}) 已添加。"
    ask_for_restart
}

# (v16.1) 配置 - TLS 隧道服务端 (SOCKS5 落地)
config_tls_socks_listener() {
    # (v16.2) 移除备份
    
    local lport
    read -p "请输入 TLS 监听端口 (例如,8.8.8.8:53): " lport
    
    if [ -z "$lport" ]; then
        print_error "本地端口不能为空。"
        return
    fi
    
    # 提醒端口唯一性
    print_warning "请确保此端口 (${lport}) 未被其他服务使用。"
    
    local cert_path="${CONFIG_DIR}/cert.pem"
    local key_path="${CONFIG_DIR}/key.pem"
    
    print_info "此服务将作为 TLS 终端，接收来自中转 VPS 的加密流量。"
    print_warning "请确保在防火墙 (安全组) 中放行 ${lport} 的 TCP 端口。"

    # [v16.1 修复] 检查并生成证书
    if [ ! -f "${cert_path}" ] || [ ! -f "${key_path}" ]; then
        print_warning "未找到 ${cert_path} 和 ${key_path}。"
        print_info "正在生成自签名证书 (有效期10年)..."
        if ! openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "${key_path}" -out "${cert_path}" \
                -subj "/C=US/ST=CA/L=MyCity/O=MyOrg/OU=MyUnit/CN=gost.local" >/dev/null 2>&1; then
            print_error "生成自签名证书失败。请确保 'openssl' 已安装。"
            return
        fi
        print_success "自签名证书生成完毕。"
    else
        print_info "检测到现有的 cert.pem/key.pem, 将直接使用。"
    fi

    init_config_file
    
    # v15.0: 写入命令行 (v2 风格, 来自 Gost转发教程.txt)
    local CMD_LINE="-L 'relay+tls://:${lport}?cert=${cert_path}&key=${key_path}'"
    echo "${CMD_LINE}" >> "${CONFIG_FILE}"

    print_success "TLS 隧道服务端 (:${lport}) 已添加到 ${CONFIG_FILE}"
    ask_for_restart
}


# (v16.5) 配置 - 删除一个指定配置
delete_specific_config() {
    # (v16.2) 移除备份
    init_config_file
    
    if [ ! -s "${CONFIG_FILE}" ]; then
        print_error "配置文件中没有找到可删除的服务。"
        return
    fi
    
    # 读取所有服务到数组
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
                
                # [v16.3 修复] 使用 -e "PATTERN" 来处理以 '-' 开头的行
                # [v16.5 修复] 检查 grep 退出码
                
                # 执行 grep 并捕获退出状态
                grep -v -F -x -e "${SERVICE_TO_DELETE}" "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp"
                local GREP_EXIT_STATUS=$?

                if [ $GREP_EXIT_STATUS -eq 0 ] || [ $GREP_EXIT_STATUS -eq 1 ]; then
                    # 退出码 0: 成功找到并排除了行 (还有其他行)
                    # 退出码 1: 成功排除了行 (这是最后一行, .tmp 为空)
                    mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
                    print_success "已删除 '$SERVICE_TO_DELETE'."
                else
                    # 退出码 > 1: Grep 真正失败
                    print_error "Grep 命令执行失败 (错误码: ${GREP_EXIT_STATUS})。配置未更改。"
                    rm -f "${CONFIG_FILE}.tmp" # 清理可能损坏的临时文件
                    break # 退出 select 循环
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
    
    # 恢复 PS3 默认值
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
        echo -e " 5. ${GREEN}添加: SOCKS5 中转 ${NC} (国内VPS常用)"
        echo -e " 6. ${GREEN}添加: TLS 隧道服务端 ${NC} (海外VPS)"
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
        echo "  Gost 转发面板管理脚本 "
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
            # v16.0: 重启会重载所有配置
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
detect_init_system

# 执行核心依赖预检查
check_core_dependencies

main_menu