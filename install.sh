#!/usr/bin/env bash
# =============================================================
# Candies Sing-box 多协议部署脚本
# Author  : Candies-Sven
# Repo    : https://github.com/candies-sven-007/proxy
# 更新    : 管理面板新增“添加新协议”功能（2026-11-17，不重装、不动已有节点）
# =============================================================
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[Candies-INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[Candies-WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[Candies-ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input
    
    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false
    ENABLE_VLESS_TLS=false
    ENABLE_ANYTLS_TLS=false

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi

    # VLESS 变体选择（Reality / TLS）
    if $ENABLE_REALITY; then
        echo ""
        echo "=== VLESS 变体（多个用空格分隔）==="
        echo "1) Reality + Vision（推荐）"
        echo "2) TLS（自签证书）"
        echo "请选择（默认 1）:"
        read -r vless_var
        vless_var="${vless_var:-1}"
        ENABLE_REALITY=false; ENABLE_VLESS_TLS=false
        for v in $vless_var; do
            case "$v" in
                1) ENABLE_REALITY=true ;;
                2) ENABLE_VLESS_TLS=true ;;
                *) warn "无效选项: $v" ;;
            esac
        done
        if ! $ENABLE_REALITY && ! $ENABLE_VLESS_TLS; then
            ENABLE_REALITY=true
        fi
    fi

    # AnyTLS 变体选择（Reality / TLS）
    if $ENABLE_ANYTLS; then
        echo ""
        echo "=== AnyTLS 变体（多个用空格分隔）==="
        echo "1) Reality（推荐）"
        echo "2) TLS（自签证书）"
        echo "请选择（默认 1）:"
        read -r anytls_var
        anytls_var="${anytls_var:-1}"
        ENABLE_ANYTLS=false; ENABLE_ANYTLS_TLS=false
        for v in $anytls_var; do
            case "$v" in
                1) ENABLE_ANYTLS=true ;;
                2) ENABLE_ANYTLS_TLS=true ;;
                *) warn "无效选项: $v" ;;
            esac
        done
        if ! $ENABLE_ANYTLS && ! $ENABLE_ANYTLS_TLS; then
            ENABLE_ANYTLS=true
        fi
    fi

    # 保存协议选择到文件（确保持久化）
    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_VLESS_TLS=$ENABLE_VLESS_TLS
ENABLE_ANYTLS_TLS=$ENABLE_ANYTLS_TLS
EOF

    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_VLESS_TLS && echo "  - VLESS TLS"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"
    $ENABLE_ANYTLS_TLS && echo "  - AnyTLS TLS"

    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
    export ENABLE_VLESS_TLS
    export ENABLE_ANYTLS_TLS
}

# 创建配置目录
mkdir -p /etc/sing-box
select_protocols

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi

    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) aes-128-gcm"
    echo "4) aes-256-gcm"
    echo "5) chacha20-ietf-poly1305"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice

    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="aes-128-gcm" ;;
        4) SS_METHOD="aes-256-gcm" ;;
        5) SS_METHOD="chacha20-ietf-poly1305" ;;
        *)
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac

    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 选择 HY2 混淆（新增）
select_hy2_obfs() {
    HY2_OBFS="none"; HY2_OBFS_PSK=""
    if ! $ENABLE_HY2; then
        return 0
    fi
    info "=== 选择 Hysteria2 混淆 ==="
    echo "1) 无混淆（推荐，兼容性最好）"
    echo "2) salamander 混淆"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r hy2_obfs_choice
    case "${hy2_obfs_choice:-1}" in
        2)
            HY2_OBFS="salamander"
            HY2_OBFS_PSK=$(rand_pass)
            info "已选择 salamander 混淆"
            ;;
        *) HY2_OBFS="none" ;;
    esac
    export HY2_OBFS HY2_OBFS_PSK
}

select_hy2_obfs

# -----------------------
# 选择 TUIC 拥塞控制（新增）
select_tuic_cc() {
    TUIC_CC="bbr"
    if ! $ENABLE_TUIC; then
        return 0
    fi
    info "=== 选择 TUIC 拥塞控制 ==="
    echo "1) bbr（推荐）"
    echo "2) cubic"
    echo "3) new_reno"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r tuic_cc_choice
    case "${tuic_cc_choice:-1}" in
        1) TUIC_CC="bbr" ;;
        2) TUIC_CC="cubic" ;;
        3) TUIC_CC="new_reno" ;;
        *)
            warn "无效选择，使用默认: bbr"
            TUIC_CC="bbr"
            ;;
    esac
    info "已选择拥塞控制: $TUIC_CC"
    export TUIC_CC
}

select_tuic_cc

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi

# 将用户选择写入缓存
mkdir -p /etc/sing-box
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f /etc/sing-box/.config_cache ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
    mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."
    
    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi

    if $ENABLE_VLESS_TLS; then
        info "=== 配置 VLESS TLS ==="
        read -p "请输入 VLESS TLS 端口(留空则随机 10000-60000): " USER_PORT_VLESS_TLS
        PORT_VLESS_TLS="${USER_PORT_VLESS_TLS:-$(rand_port)}"
        UUID_VLESS_TLS=$(rand_uuid)
        info "VLESS TLS 端口: $PORT_VLESS_TLS"
        info "VLESS TLS UUID 已自动生成"
    fi

    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
    info "AnyTLS Reality 密码已自动生成"
    fi

    if $ENABLE_ANYTLS_TLS; then
        info "=== 配置 AnyTLS TLS ==="
        read -p "请输入 AnyTLS TLS 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS_TLS
        PORT_ANYTLS_TLS="${USER_PORT_ANYTLS_TLS:-$(rand_port)}"
        ANYTLS_TLS_USER=$(openssl rand -hex 4)
        ANYTLS_TLS_PSK=$(openssl rand -base64 16)
        info "AnyTLS TLS 端口: $PORT_ANYTLS_TLS"
        info "AnyTLS TLS 用户名: $ANYTLS_TLS_USER"
        info "AnyTLS TLS 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi
    
    info "生成 Reality 密钥对..."
    
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi
    
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }
    
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }
    
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi
    
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_VLESS_TLS && ! $ENABLE_ANYTLS_TLS; then
        info "跳过证书生成(未选择 HY2、TUIC 或 TLS 变体)"
        return 0
    fi

    info "生成 HY2/TUIC/TLS 自签证书..."
    mkdir -p /etc/sing-box/certs
    
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"
    
    local need_comma=false
    
    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
OBFS_HY2_PLACEHOLDER
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        if [ "${HY2_OBFS:-none}" = "salamander" ]; then
            sed -i "s|OBFS_HY2_PLACEHOLDER|      \"obfs\": {\"type\": \"salamander\", \"password\": \"$HY2_OBFS_PSK\"},|" "$TEMP_INBOUNDS"
        else
            sed -i "/OBFS_HY2_PLACEHOLDER/d" "$TEMP_INBOUNDS"
        fi
        need_comma=true
    fi

    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "TUIC_CC_PLACEHOLDER",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|TUIC_CC_PLACEHOLDER|${TUIC_CC:-bbr}|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi
    
    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_VLESS_TLS; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_VLESS_TLS'
    {
      "type": "vless",
      "tag": "vless-tls-in",
      "listen": "::",
      "listen_port": PORT_VLESS_TLS_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_VLESS_TLS_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_VLESS_TLS
        sed -i "s|PORT_VLESS_TLS_PLACEHOLDER|$PORT_VLESS_TLS|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_VLESS_TLS_PLACEHOLDER|$UUID_VLESS_TLS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi


    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    if $ENABLE_ANYTLS_TLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS_TLS'
    {
      "type": "anytls",
      "tag": "anytls-tls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_TLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_TLS_USER_PLACEHOLDER",
          "password": "ANYTLS_TLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_ANYTLS_TLS

    sed -i "s|PORT_ANYTLS_TLS_PLACEHOLDER|$PORT_ANYTLS_TLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_TLS_USER_PLACEHOLDER|$ANYTLS_TLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_TLS_PSK_PLACEHOLDER|$ANYTLS_TLS_PSK|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD
    
    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
    
    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    rm -f "$TEMP_INBOUNDS"

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败,但继续执行"

    # 保存配置缓存（追加/覆盖）
    cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_VLESS_TLS=$ENABLE_VLESS_TLS
ENABLE_ANYTLS_TLS=$ENABLE_ANYTLS_TLS
CACHEEOF

    $ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
HY2_OBFS=$HY2_OBFS
HY2_OBFS_PSK=$HY2_OBFS_PSK
CACHEEOF

    $ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
TUIC_CC=$TUIC_CC
CACHEEOF

    $ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_VLESS_TLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
VLESS_TLS_PORT=$PORT_VLESS_TLS
VLESS_TLS_UUID=$UUID_VLESS_TLS
CACHEEOF

    $ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    $ENABLE_ANYTLS_TLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_TLS_PORT=$PORT_ANYTLS_TLS
ANYTLS_TLS_USER=$ANYTLS_TLS_USER
ANYTLS_TLS_PSK=$ANYTLS_TLS_PSK
CACHEEOF

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> /etc/sing-box/.config_cache

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

# 调用配置生成
create_config

info "配置生成完成，准备设置服务..."

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host="$PUB_IP"
    
    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi
    
    if $ENABLE_HY2; then
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi
    
    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: /etc/sing-box/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令:"
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="

# -----------------------
# 创建 sb 管理脚本
SB_PATH="/usr/local/bin/candies-sb"
info "正在创建 candies-sb 管理面板: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[Candies-INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[Candies-WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[Candies-ERR]\033[0m $*" >&2; }

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# 服务控制
service_start() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"
}
service_stop() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"
}
service_restart() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"
}
service_status() {
    [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    # 优先加载 .protocols 文件（确认协议标记）
    PROTOCOL_FILE="/etc/sing-box/.protocols"
    if [ -f "$PROTOCOL_FILE" ]; then
        . "$PROTOCOL_FILE"
    fi

    # 加载缓存文件（包含端口密码等详细配置）
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi

    # 确保有默认值（新变体开关默认 false，保持旧配置兼容）
    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    ENABLE_ANYTLS="${ENABLE_ANYTLS:-false}"
    ENABLE_VLESS_TLS="${ENABLE_VLESS_TLS:-false}"
    ENABLE_ANYTLS_TLS="${ENABLE_ANYTLS_TLS:-false}"
    CUSTOM_IP="${CUSTOM_IP:-}"
    HY2_OBFS="${HY2_OBFS:-none}"
    TUIC_CC="${TUIC_CC:-bbr}"

    # 读取各协议配置（按 tag 读，同一类型多个变体时互不干扰）
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        SS_PSK=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .password // empty' "$CONFIG_PATH" | head -n1)
        SS_METHOD=$(jq -r '.inbounds[] | select(.tag=="ss-in") | .method // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        HY2_PSK=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
        HY2_OBFS=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .obfs.type // "none"' "$CONFIG_PATH" | head -n1)
        HY2_OBFS_PSK=$(jq -r '.inbounds[] | select(.tag=="hy2-in") | .obfs.password // empty' "$CONFIG_PATH" | head -n1)
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
        TUIC_UUID=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
        TUIC_PSK=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
        TUIC_CC=$(jq -r '.inbounds[] | select(.tag=="tuic-in") | .congestion_control // "bbr"' "$CONFIG_PATH" | head -n1)
    fi

# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '
        .inbounds[]
        | select(.tls.reality.enabled == true)
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH" | head -n1)

    [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
fi

# VLESS Reality 专属参数
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    REALITY_UUID=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
    REALITY_PK=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
fi

# VLESS TLS 专属参数
if [ "${ENABLE_VLESS_TLS:-false}" = "true" ]; then
    VLESS_TLS_PORT=$(jq -r '.inbounds[] | select(.tag=="vless-tls-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    VLESS_TLS_UUID=$(jq -r '.inbounds[] | select(.tag=="vless-tls-in") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
fi


if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi

# AnyTLS TLS 专属参数
if [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ]; then
    ANYTLS_TLS_PORT=$(jq -r '.inbounds[] | select(.tag=="anytls-tls-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_TLS_USER=$(jq -r '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].name // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_TLS_PSK=$(jq -r '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
    
    URI_FILE="/etc/sing-box/uris.txt"
    > "$URI_FILE"
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')
        
        echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        echo "=== Hysteria2 (HY2) ===" >> "$URI_FILE"
        if [ "${HY2_OBFS:-none}" = "salamander" ] && [ -n "${HY2_OBFS_PSK:-}" ]; then
            hy2_obfs_encoded=$(url_encode "$HY2_OBFS_PSK")
            echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1&obfs=salamander&obfs-password=${hy2_obfs_encoded}#hy2${node_suffix}" >> "$URI_FILE"
        else
            echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$URI_FILE"
        fi
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$URI_FILE"
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=${TUIC_CC:-bbr}&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$URI_FILE"
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_VLESS_TLS:-false}" = "true" ]; then
        echo "=== VLESS TLS ===" >> "$URI_FILE"
        echo "vless://${VLESS_TLS_UUID}@${PUBLIC_IP}:${VLESS_TLS_PORT}?encryption=none&security=tls&sni=www.bing.com&fp=chrome&allowInsecure=1#vless-tls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi


    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$URI_FILE"
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    if [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ]; then
        anytls_tls_user_encoded=$(url_encode "$ANYTLS_TLS_USER")
        anytls_tls_pass_encoded=$(url_encode "$ANYTLS_TLS_PSK")
        echo "=== AnyTLS TLS ===" >> "$URI_FILE"
        echo "anytls://${anytls_tls_user_encoded}:${anytls_tls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_TLS_PORT}/?security=tls&sni=www.bing.com&fp=chrome&allowInsecure=1#anytls-tls${node_suffix}" >> "$URI_FILE"
        echo "" >> "$URI_FILE"
    fi

    info "URI 已保存到: $URI_FILE"
}

# 查看URI
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat /etc/sing-box/uris.txt
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi
    
    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"
    
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过,已重启服务"
            service_restart || warn "重启失败"
            generate_uris || true
        else
            warn "配置校验失败,服务未重启"
        fi
    fi
}

# 询问端口（回车随机，校验范围、重复与系统占用）
ask_port() {
    local name="$1" input
    while true; do
        read -p "请输入 $name 端口(留空则随机 10000-60000): " input
        input="${input:-$(rand_port)}"
        if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
            warn "端口无效: $input,请输入 1-65535" >&2
            continue
        fi
        if jq -e --argjson p "$input" '.inbounds[] | select(.listen_port == $p)' "$CONFIG_PATH" >/dev/null 2>&1; then
            warn "端口 $input 已被现有节点占用,请换一个" >&2
            continue
        fi
        if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":${input} "; then
            warn "端口 $input 已被系统其他服务占用,请换一个" >&2
            continue
        fi
        echo "$input"
        return 0
    done
}

# HY2/TUIC 自签证书（没有就生成，已有就复用）
ensure_cert() {
    mkdir -p /etc/sing-box/certs
    if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
        info "生成 HY2/TUIC 自签证书..."
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /etc/sing-box/certs/privkey.pem \
          -out /etc/sing-box/certs/fullchain.pem \
          -days 3650 \
          -subj "/CN=www.bing.com" || { err "证书生成失败"; return 1; }
        info "证书已生成"
    else
        info "证书已存在,复用"
    fi
}

# Reality 密钥对（已有就复用，没有就生成）
ensure_reality_keys() {
    local existing_pk existing_sid sni_input keys
    existing_pk=$(jq -r '.inbounds[] | select(.tls.reality.enabled == true) | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1)
    if [ -n "$existing_pk" ]; then
        REALITY_PK="$existing_pk"
        REALITY_SID=$(jq -r '.inbounds[] | select(.tls.reality.enabled == true) | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1)
        [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        info "复用已有 Reality 密钥对"
        return 0
    fi
    # 配置里没有，再看缓存里是否留有上次的密钥对（卸载/切换后保留，复用可保持订阅链接不变）
    if [ -n "${REALITY_PK:-}" ] && [ -n "${REALITY_PUB:-}" ] && [ -n "${REALITY_SID:-}" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        info "复用缓存里的 Reality 密钥对"
        return 0
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装,无法生成 Reality 密钥"
        return 1
    fi
    info "生成 Reality 密钥对..."
    keys=$(sing-box generate reality-keypair 2>&1) || { err "生成 Reality 密钥失败"; return 1; }
    REALITY_PK=$(echo "$keys" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$keys" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || { err "生成 Reality ShortID 失败"; return 1; }
    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        return 1
    fi
    read -p "请输入 Reality 的 SNI(留空默认 addons.mozilla.org): " sni_input
    REALITY_SNI="$(echo "${sni_input:-addons.mozilla.org}" | tr -d '[:space:]')"
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    info "Reality 密钥已生成"
}

# 更新 .config_cache 里的协议开关（read_config 先读 .protocols 再读缓存，两个都要改）
update_cache_flags() {
    local key val
    for key in ENABLE_SS ENABLE_HY2 ENABLE_TUIC ENABLE_REALITY ENABLE_ANYTLS ENABLE_VLESS_TLS ENABLE_ANYTLS_TLS; do
        val="${!key:-false}"
        if grep -q "^${key}=" "$CACHE_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$CACHE_FILE"
        else
            echo "${key}=${val}" >> "$CACHE_FILE"
        fi
    done
}

# 添加新协议（不重装、不动已有节点；选协议后再选变体）
action_add_protocol() {
    read_config || return 1

    if ! command -v jq >/dev/null 2>&1; then
        err "缺少 jq,请先安装 jq"
        return 1
    fi

    info "=== 添加新协议 ==="
    echo "1) Shadowsocks (SS)   [ $([ "${ENABLE_SS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
    echo "2) Hysteria2 (HY2)   [ $([ "${ENABLE_HY2:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
    echo "3) TUIC              [ $([ "${ENABLE_TUIC:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
    echo "4) VLESS             [ Reality:$([ "${ENABLE_REALITY:-false}" = "true" ] && echo 已安装 || echo 未安装) TLS:$([ "${ENABLE_VLESS_TLS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
    echo "5) AnyTLS            [ Reality:$([ "${ENABLE_ANYTLS:-false}" = "true" ] && echo 已安装 || echo 未安装) TLS:$([ "${ENABLE_ANYTLS_TLS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
    echo ""
    echo "请输入要添加的协议编号(多个用空格分隔,如: 1 3,回车取消):"
    read -r add_input
    [ -z "${add_input:-}" ] && { info "已取消"; return 0; }

    # 变体键：ss / hy2 / tuic / vless-reality / vless-tls / anytls-reality / anytls-tls
    local to_add="" n v
    for n in $add_input; do
        case "$n" in
            1)
                [ "${ENABLE_SS:-false}" = "true" ] && warn "SS 已安装,跳过" || to_add="$to_add ss"
                ;;
            2)
                [ "${ENABLE_HY2:-false}" = "true" ] && warn "HY2 已安装,跳过" || to_add="$to_add hy2"
                ;;
            3)
                [ "${ENABLE_TUIC:-false}" = "true" ] && warn "TUIC 已安装,跳过" || to_add="$to_add tuic"
                ;;
            4)
                echo "--- VLESS 变体（多个用空格分隔）---"
                echo "1) Reality + Vision（推荐）  [ $([ "${ENABLE_REALITY:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
                echo "2) TLS（自签证书）          [ $([ "${ENABLE_VLESS_TLS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
                echo "请选择（默认 1，回车跳过）:"
                read -r v
                [ -z "${v:-}" ] && continue
                for v in $v; do
                    case "$v" in
                        1) [ "${ENABLE_REALITY:-false}" = "true" ] && warn "VLESS Reality 已安装,跳过" || to_add="$to_add vless-reality" ;;
                        2) [ "${ENABLE_VLESS_TLS:-false}" = "true" ] && warn "VLESS TLS 已安装,跳过" || to_add="$to_add vless-tls" ;;
                        *) warn "无效选项: $v" ;;
                    esac
                done
                ;;
            5)
                echo "--- AnyTLS 变体（多个用空格分隔）---"
                echo "1) Reality（推荐）  [ $([ "${ENABLE_ANYTLS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
                echo "2) TLS（自签证书）  [ $([ "${ENABLE_ANYTLS_TLS:-false}" = "true" ] && echo 已安装 || echo 未安装) ]"
                echo "请选择（默认 1，回车跳过）:"
                read -r v
                [ -z "${v:-}" ] && continue
                for v in $v; do
                    case "$v" in
                        1) [ "${ENABLE_ANYTLS:-false}" = "true" ] && warn "AnyTLS Reality 已安装,跳过" || to_add="$to_add anytls-reality" ;;
                        2) [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ] && warn "AnyTLS TLS 已安装,跳过" || to_add="$to_add anytls-tls" ;;
                        *) warn "无效选项: $v" ;;
                    esac
                done
                ;;
            *) warn "无效选项: $n" ;;
        esac
    done
    [ -z "${to_add// /}" ] && { warn "没有可添加的协议"; return 1; }

    local need_cert=false need_reality=false k
    for k in $to_add; do
        case "$k" in
            hy2|tuic|vless-tls|anytls-tls) need_cert=true ;;
            vless-reality|anytls-reality) need_reality=true ;;
        esac
    done

    if $need_cert; then
        ensure_cert || return 1
    fi
    if $need_reality; then
        ensure_reality_keys || return 1
    fi

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "已备份现有配置: ${CONFIG_PATH}.bak"

    local new_inbounds_file="/tmp/singbox_new_inbounds_$$.json"
    local one_file="/tmp/sb_new_one_$$.json"
    echo "[]" > "$new_inbounds_file"

    local port method psk uuid m obfs_psk cc xpath
    for k in $to_add; do
        case "$k" in
            ss)
                port=$(ask_port "SS") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                echo "SS 加密方式：1) 2022-blake3-aes-128-gcm(推荐) 2) 2022-blake3-aes-256-gcm 3) aes-128-gcm 4) aes-256-gcm 5) chacha20-ietf-poly1305 [默认1]:"
                read -r m
                case "${m:-1}" in
                    1) method="2022-blake3-aes-128-gcm" ;;
                    2) method="2022-blake3-aes-256-gcm" ;;
                    3) method="aes-128-gcm" ;;
                    4) method="aes-256-gcm" ;;
                    5) method="chacha20-ietf-poly1305" ;;
                    *) method="2022-blake3-aes-128-gcm" ;;
                esac
                psk=$(rand_pass)
                SS_PORT="$port"; SS_PSK="$psk"; SS_METHOD="$method"
                jq -n --argjson port "$port" --arg method "$method" --arg psk "$psk" \
                    '{type:"shadowsocks",listen:"::",listen_port:$port,method:$method,password:$psk,tag:"ss-in"}' > "$one_file"
                ;;
            hy2)
                port=$(ask_port "HY2") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                echo "HY2 混淆：1) 无混淆（推荐） 2) salamander [默认1]:"
                read -r m
                psk=$(rand_pass)
                HY2_PORT="$port"; HY2_PSK="$psk"
                if [ "${m:-1}" = "2" ]; then
                    obfs_psk=$(rand_pass)
                    HY2_OBFS="salamander"; HY2_OBFS_PSK="$obfs_psk"
                    jq -n --argjson port "$port" --arg psk "$psk" --arg obfs_psk "$obfs_psk" \
                        '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$psk}],obfs:{type:"salamander",password:$obfs_psk},tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$one_file"
                else
                    HY2_OBFS="none"; HY2_OBFS_PSK=""
                    jq -n --argjson port "$port" --arg psk "$psk" \
                        '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$psk}],tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$one_file"
                fi
                ;;
            tuic)
                port=$(ask_port "TUIC") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                echo "TUIC 拥塞控制：1) bbr（推荐） 2) cubic 3) new_reno [默认1]:"
                read -r m
                case "${m:-1}" in
                    1) cc="bbr" ;;
                    2) cc="cubic" ;;
                    3) cc="new_reno" ;;
                    *) cc="bbr" ;;
                esac
                uuid=$(rand_uuid); psk=$(rand_pass)
                TUIC_PORT="$port"; TUIC_UUID="$uuid"; TUIC_PSK="$psk"; TUIC_CC="$cc"
                jq -n --argjson port "$port" --arg uuid "$uuid" --arg psk "$psk" --arg cc "$cc" \
                    '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$psk}],congestion_control:$cc,tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$one_file"
                ;;
            vless-reality)
                port=$(ask_port "VLESS Reality") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                uuid=$(rand_uuid)
                REALITY_PORT="$port"; REALITY_UUID="$uuid"
                jq -n --argjson port "$port" --arg uuid "$uuid" --arg sni "$REALITY_SNI" --arg pk "$REALITY_PK" --arg sid "$REALITY_SID" \
                    '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$one_file"
                ;;
            vless-tls)
                port=$(ask_port "VLESS TLS") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                uuid=$(rand_uuid)
                VLESS_TLS_PORT="$port"; VLESS_TLS_UUID="$uuid"
                jq -n --argjson port "$port" --arg uuid "$uuid" \
                    '{type:"vless",tag:"vless-tls-in",listen:"::",listen_port:$port,users:[{uuid:$uuid}],tls:{enabled:true,server_name:"www.bing.com",certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$one_file"
                ;;
            anytls-reality)
                port=$(ask_port "AnyTLS Reality") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                ANYTLS_PORT="$port"
                ANYTLS_USER=$(openssl rand -hex 4)
                ANYTLS_PSK=$(rand_pass)
                jq -n --argjson port "$port" --arg user "$ANYTLS_USER" --arg psk "$ANYTLS_PSK" --arg sni "$REALITY_SNI" --arg pk "$REALITY_PK" --arg sid "$REALITY_SID" \
                    '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$psk}],padding_scheme:[],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$one_file"
                ;;
            anytls-tls)
                port=$(ask_port "AnyTLS TLS") || { rm -f "$new_inbounds_file" "$one_file"; return 1; }
                ANYTLS_TLS_PORT="$port"
                ANYTLS_TLS_USER=$(openssl rand -hex 4)
                ANYTLS_TLS_PSK=$(rand_pass)
                jq -n --argjson port "$port" --arg user "$ANYTLS_TLS_USER" --arg psk "$ANYTLS_TLS_PSK" \
                    '{type:"anytls",tag:"anytls-tls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$psk}],padding_scheme:[],tls:{enabled:true,server_name:"www.bing.com",certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$one_file"
                ;;
        esac
        if ! jq --slurpfile one "$one_file" '. + $one' "$new_inbounds_file" > "${new_inbounds_file}.tmp"; then
            err "生成入站配置失败"
            rm -f "$new_inbounds_file" "${new_inbounds_file}.tmp" "$one_file"
            return 1
        fi
        mv "${new_inbounds_file}.tmp" "$new_inbounds_file"
    done
    rm -f "$one_file"

    # 把新入站追加进配置（已有入站原样保留）
    # 注意：new_inbounds_file 本身已是 JSON 数组，不能用 --slurpfile（会再包一层数组），改用 -s
    if ! jq -s '.[0].inbounds += .[1] | .[0]' "$CONFIG_PATH" "$new_inbounds_file" > "${CONFIG_PATH}.tmp"; then
        err "写入配置失败,已恢复原配置"
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        rm -f "$new_inbounds_file" "${CONFIG_PATH}.tmp"
        return 1
    fi
    mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    # 更新协议开关（.protocols 与 .config_cache 都要改）
    for k in $to_add; do
        case "$k" in
            ss) ENABLE_SS=true ;;
            hy2) ENABLE_HY2=true ;;
            tuic) ENABLE_TUIC=true ;;
            vless-reality) ENABLE_REALITY=true ;;
            vless-tls) ENABLE_VLESS_TLS=true ;;
            anytls-reality) ENABLE_ANYTLS=true ;;
            anytls-tls) ENABLE_ANYTLS_TLS=true ;;
        esac
    done
    printf 'ENABLE_SS=%s\nENABLE_HY2=%s\nENABLE_TUIC=%s\nENABLE_REALITY=%s\nENABLE_ANYTLS=%s\nENABLE_VLESS_TLS=%s\nENABLE_ANYTLS_TLS=%s\n' \
        "$ENABLE_SS" "$ENABLE_HY2" "$ENABLE_TUIC" "$ENABLE_REALITY" "$ENABLE_ANYTLS" "$ENABLE_VLESS_TLS" "$ENABLE_ANYTLS_TLS" > /etc/sing-box/.protocols
    update_cache_flags

    # 把新协议凭据追加进缓存（与安装脚本同一格式；链接实际以 config.json 为准）
    for k in $to_add; do
        case "$k" in
            ss) printf 'SS_PORT=%s\nSS_PSK=%s\nSS_METHOD=%s\n' "$SS_PORT" "$SS_PSK" "$SS_METHOD" >> "$CACHE_FILE" ;;
            hy2) printf 'HY2_PORT=%s\nHY2_PSK=%s\nHY2_OBFS=%s\nHY2_OBFS_PSK=%s\n' "$HY2_PORT" "$HY2_PSK" "$HY2_OBFS" "$HY2_OBFS_PSK" >> "$CACHE_FILE" ;;
            tuic) printf 'TUIC_PORT=%s\nTUIC_UUID=%s\nTUIC_PSK=%s\nTUIC_CC=%s\n' "$TUIC_PORT" "$TUIC_UUID" "$TUIC_PSK" "$TUIC_CC" >> "$CACHE_FILE" ;;
            vless-reality) printf 'REALITY_PORT=%s\nREALITY_UUID=%s\nREALITY_PK=%s\nREALITY_SID=%s\nREALITY_PUB=%s\nREALITY_SNI=%s\n' "$REALITY_PORT" "$REALITY_UUID" "$REALITY_PK" "$REALITY_SID" "$REALITY_PUB" "$REALITY_SNI" >> "$CACHE_FILE" ;;
            vless-tls) printf 'VLESS_TLS_PORT=%s\nVLESS_TLS_UUID=%s\n' "$VLESS_TLS_PORT" "$VLESS_TLS_UUID" >> "$CACHE_FILE" ;;
            anytls-reality) printf 'ANYTLS_PORT=%s\nANYTLS_USER=%s\nANYTLS_PSK=%s\n' "$ANYTLS_PORT" "$ANYTLS_USER" "$ANYTLS_PSK" >> "$CACHE_FILE" ;;
            anytls-tls) printf 'ANYTLS_TLS_PORT=%s\nANYTLS_TLS_USER=%s\nANYTLS_TLS_PSK=%s\n' "$ANYTLS_TLS_PORT" "$ANYTLS_TLS_USER" "$ANYTLS_TLS_PSK" >> "$CACHE_FILE" ;;
        esac
    done

    # 校验配置（失败则回滚）
    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置校验失败,已恢复原配置"
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        rm -f "$new_inbounds_file"
        return 1
    fi
    rm -f "$new_inbounds_file"

    info "配置校验通过,正在重启服务..."
    service_restart || warn "重启失败,请手动检查"
    sleep 1
    info "✅ 新协议已添加,链接如下:"
    action_view_uri || warn "生成 URI 失败"
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1
    
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi
    
    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="ss-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1
    
    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi
    
    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="hy2-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1
    
    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi
    
    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="tuic-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1
    
    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi
    
    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    
    info "正在停止服务..."
    service_stop || warn "停止服务失败"
    
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    
    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="vless-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    
    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless TLS端口
action_reset_vless_tls() {
    read_config || return 1

    if [ "${ENABLE_VLESS_TLS:-false}" != "true" ]; then
        err "Vless TLS 协议未启用"
        return 1
    fi

    read -p "输入新的 Vless TLS 端口(回车保持 $VLESS_TLS_PORT): " new_port
    new_port="${new_port:-$VLESS_TLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="vless-tls-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 Vless TLS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}


# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="anytls-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS TLS端口
action_reset_anytls_tls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS_TLS:-false}" != "true" ]; then
        err "AnyTLS TLS 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS TLS 端口(回车保持 $ANYTLS_TLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_TLS_PORT}"

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .tag=="anytls-tls-in" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS TLS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi
    
    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0
    
    info "正在卸载..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/candies-sb /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
action_generate_relay() {
    read_config || return 1
    
    # 检查是否启用了SS
    if [ "${ENABLE_SS:-false}" != "true" ]; then
        warn "未检测到 SS 协议,需要先部署 SS 作为入站"
        read -p "是否现在部署 SS 协议?(y/N): " deploy_ss
        if [[ "$deploy_ss" =~ ^[Yy]$ ]]; then
            info "开始部署 SS 协议..."
            
            # 让用户选择端口
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_SS_PORT
            SS_PORT="${USER_SS_PORT:-$(rand_port)}"
            SS_PSK=$(rand_pass)
            SS_METHOD="aes-128-gcm"
            
            info "SS 端口: $SS_PORT | 密码已自动生成"
            
            info "正在停止服务..."
            service_stop || warn "停止服务失败"
            
            cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
            
            # 添加 SS inbound
            jq --argjson port "$SS_PORT" --arg psk "$SS_PSK" '
            .inbounds += [{
              "type": "shadowsocks",
              "listen": "::",
              "listen_port": $port,
              "method": "aes-128-gcm",
              "password": $psk,
              "tag": "ss-in"
            }]
            ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            
            # 更新缓存和协议标记
            sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$CACHE_FILE" 2>/dev/null || echo "ENABLE_SS=true" >> "$CACHE_FILE"
            echo "SS_PORT=$SS_PORT" >> "$CACHE_FILE"
            echo "SS_PSK=$SS_PSK" >> "$CACHE_FILE"
            echo "SS_METHOD=$SS_METHOD" >> "$CACHE_FILE"
            
            # 同步更新协议标记文件
            PROTOCOL_FILE="/etc/sing-box/.protocols"
            if [ -f "$PROTOCOL_FILE" ]; then
                sed -i 's/ENABLE_SS=false/ENABLE_SS=true/' "$PROTOCOL_FILE"
            else
                echo "ENABLE_SS=true" >> "$PROTOCOL_FILE"
            fi
            
            # 更新当前会话变量
            ENABLE_SS=true
            
            info "SS 已部署 - 端口: $SS_PORT"
            service_start || warn "启动服务失败"
            sleep 1
            
            # 重新读取配置
            read_config
        else
            err "取消生成线路机脚本"
            return 1
        fi
    fi
    
    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"
    
    info "正在生成线路机脚本: $RELAY_SCRIPT"
    
    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[Candies-INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[Candies-ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-addons.mozilla.org}|g" "$RELAY_SCRIPT"
    
    chmod +x "$RELAY_SCRIPT"
    
    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 动态生成菜单
# -----------------------
# 卸载 / 恢复 / 切换（新增）
# 卸载时把整条入站（含端口、密码、UUID、Reality 密钥）备份到 $REMOVED_DIR，
# 恢复时原样装回，凭据不变；切换变体时尽量保留端口与凭据。
# -----------------------
REMOVED_DIR="/etc/sing-box/.removed"

# tag → .protocols 开关
tag_to_flag() {
    case "$1" in
        ss-in) echo "ENABLE_SS" ;;
        hy2-in) echo "ENABLE_HY2" ;;
        tuic-in) echo "ENABLE_TUIC" ;;
        vless-in) echo "ENABLE_REALITY" ;;
        vless-tls-in) echo "ENABLE_VLESS_TLS" ;;
        anytls-in) echo "ENABLE_ANYTLS" ;;
        anytls-tls-in) echo "ENABLE_ANYTLS_TLS" ;;
        *) echo "" ;;
    esac
}

# tag → 显示名
tag_to_name() {
    case "$1" in
        ss-in) echo "Shadowsocks (SS)" ;;
        hy2-in) echo "Hysteria2 (HY2)" ;;
        tuic-in) echo "TUIC" ;;
        vless-in) echo "VLESS Reality" ;;
        vless-tls-in) echo "VLESS TLS" ;;
        anytls-in) echo "AnyTLS Reality" ;;
        anytls-tls-in) echo "AnyTLS TLS" ;;
        *) echo "$1" ;;
    esac
}

# tag → 专属缓存键（空格分隔；Reality 共享密钥另行处理）
tag_cache_keys() {
    case "$1" in
        ss-in) echo "SS_PORT SS_PSK SS_METHOD" ;;
        hy2-in) echo "HY2_PORT HY2_PSK HY2_OBFS HY2_OBFS_PSK" ;;
        tuic-in) echo "TUIC_PORT TUIC_UUID TUIC_PSK TUIC_CC" ;;
        vless-in) echo "REALITY_PORT REALITY_UUID" ;;
        vless-tls-in) echo "VLESS_TLS_PORT VLESS_TLS_UUID" ;;
        anytls-in) echo "ANYTLS_PORT ANYTLS_USER ANYTLS_PSK" ;;
        anytls-tls-in) echo "ANYTLS_TLS_PORT ANYTLS_TLS_USER ANYTLS_TLS_PSK" ;;
        *) echo "" ;;
    esac
}

# 已安装的 tag（每行一个）
installed_tags() {
    [ "${ENABLE_SS:-false}" = "true" ] && echo "ss-in"
    [ "${ENABLE_HY2:-false}" = "true" ] && echo "hy2-in"
    [ "${ENABLE_TUIC:-false}" = "true" ] && echo "tuic-in"
    [ "${ENABLE_REALITY:-false}" = "true" ] && echo "vless-in"
    [ "${ENABLE_VLESS_TLS:-false}" = "true" ] && echo "vless-tls-in"
    [ "${ENABLE_ANYTLS:-false}" = "true" ] && echo "anytls-in"
    [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ] && echo "anytls-tls-in"
}

# tag 的监听端口
tag_port() {
    jq -r --arg t "$1" '.inbounds[] | select(.tag==$t) | .listen_port // empty' "$CONFIG_PATH" 2>/dev/null | head -n1
}

# 设置/删除缓存键（值里可能含 / = 等字符，用删行再追加，避免 sed 替换转义问题）
set_cache_key() {
    local k="$1" v="$2"
    sed -i "/^${k}=/d" "$CACHE_FILE" 2>/dev/null
    echo "${k}=${v}" >> "$CACHE_FILE"
}
del_cache_key() {
    sed -i "/^${1}=/d" "$CACHE_FILE" 2>/dev/null
}

# 备份一条已安装的入站（配置 + 凭据）到 $REMOVED_DIR/<tag>.json
backup_inbound() {
    local tag="$1" name inbound_json cache_json keys k v ts
    name=$(tag_to_name "$tag")
    mkdir -p "$REMOVED_DIR"
    inbound_json=$(jq -c --arg t "$tag" '.inbounds[] | select(.tag==$t)' "$CONFIG_PATH" 2>/dev/null)
    [ -z "$inbound_json" ] || [ "$inbound_json" = "null" ] && { err "未找到入站: $tag"; return 1; }
    cache_json="{}"
    keys=$(tag_cache_keys "$tag")
    for k in $keys; do
        v=$(grep "^${k}=" "$CACHE_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)
        [ -n "$v" ] && cache_json=$(echo "$cache_json" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')
    done
    # Reality 变体额外备份共享密钥（恢复时若已存在则值相同，覆盖无害）
    case "$tag" in
        vless-in|anytls-in)
            for k in REALITY_PK REALITY_PUB REALITY_SID REALITY_SNI; do
                v=$(grep "^${k}=" "$CACHE_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)
                [ -n "$v" ] && cache_json=$(echo "$cache_json" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')
            done
            ;;
    esac
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M")
    jq -n --arg tag "$tag" --arg name "$name" --arg ts "$ts" --argjson inbound "$inbound_json" --argjson cache "$cache_json" \
        '{tag:$tag, name:$name, removed_at:$ts, inbound:$inbound, cache:$cache}' > "$REMOVED_DIR/$tag.json" \
        || { err "备份写入失败: $tag"; return 1; }
    info "已备份 $name 到 $REMOVED_DIR/$tag.json"
}

# 卸载协议（备份凭据，之后可原样恢复）
action_uninstall_protocol() {
    read_config || return 1
    if ! command -v jq >/dev/null 2>&1; then
        err "缺少 jq,请先安装 jq"
        return 1
    fi
    local tags_list
    tags_list=$(installed_tags)
    [ -z "$tags_list" ] && { warn "没有已安装的协议"; return 1; }
    info "=== 卸载协议（会备份凭据，之后可原样恢复）==="
    local i=1 tag name port
    local -a arr
    while IFS= read -r tag; do
        [ -z "$tag" ] && continue
        name=$(tag_to_name "$tag"); port=$(tag_port "$tag")
        echo "$i) $name  [端口 $port]"
        arr[$i]="$tag"
        i=$((i+1))
    done <<< "$tags_list"
    echo "请选择要卸载的编号(多个用空格分隔，回车取消):"
    read -r input
    [ -z "${input:-}" ] && { info "已取消"; return 0; }
    local to_remove="" n
    for n in $input; do
        tag="${arr[$n]:-}"
        [ -z "$tag" ] && { warn "无效选项: $n"; continue; }
        to_remove="$to_remove $tag"
    done
    [ -z "${to_remove// /}" ] && { warn "没有可卸载的协议"; return 1; }
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "已备份现有配置: ${CONFIG_PATH}.bak"
    local flag keys k
    for tag in $to_remove; do
        name=$(tag_to_name "$tag")
        backup_inbound "$tag" || { warn "备份 $name 失败，跳过"; continue; }
        if ! jq --arg t "$tag" 'del(.inbounds[] | select(.tag==$t))' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"; then
            err "删除 $name 失败"
            cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            return 1
        fi
        mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        flag=$(tag_to_flag "$tag")
        eval "$flag=false"
        keys=$(tag_cache_keys "$tag")
        for k in $keys; do
            del_cache_key "$k"
        done
        # Reality 共享密钥对保留在缓存里不删：以后恢复/重装 Reality 变体时复用，订阅链接不变
        info "已卸载 $name（凭据已备份）"
    done
    printf 'ENABLE_SS=%s\nENABLE_HY2=%s\nENABLE_TUIC=%s\nENABLE_REALITY=%s\nENABLE_ANYTLS=%s\nENABLE_VLESS_TLS=%s\nENABLE_ANYTLS_TLS=%s\n' \
        "$ENABLE_SS" "$ENABLE_HY2" "$ENABLE_TUIC" "$ENABLE_REALITY" "$ENABLE_ANYTLS" "$ENABLE_VLESS_TLS" "$ENABLE_ANYTLS_TLS" > /etc/sing-box/.protocols
    update_cache_flags
    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置校验失败，已恢复原配置"
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        return 1
    fi
    info "配置校验通过，正在重启服务..."
    service_restart || warn "重启失败，请手动检查"
    sleep 1
    generate_uris || warn "生成 URI 失败"
    info "✅ 卸载完成。备份在 /etc/sing-box/.removed/，用菜单里的“恢复已卸载协议”可原样装回（端口、密码、密钥都不变）。"
}

# 恢复已卸载的协议（端口、密码、密钥原样恢复）
action_restore_protocol() {
    read_config || return 1
    if ! command -v jq >/dev/null 2>&1; then
        err "缺少 jq,请先安装 jq"
        return 1
    fi
    mkdir -p "$REMOVED_DIR"
    local files
    files=$(ls "$REMOVED_DIR"/*.json 2>/dev/null)
    [ -z "$files" ] && { warn "没有已卸载的协议备份（$REMOVED_DIR 为空）"; return 1; }
    info "=== 恢复已卸载协议（端口、密码、密钥原样恢复）==="
    local i=1 f tag name port removed_at
    local -a arr
    for f in $files; do
        tag=$(jq -r '.tag // empty' "$f" 2>/dev/null)
        name=$(jq -r '.name // empty' "$f" 2>/dev/null)
        port=$(jq -r '.inbound.listen_port // empty' "$f" 2>/dev/null)
        removed_at=$(jq -r '.removed_at // empty' "$f" 2>/dev/null)
        [ -z "$tag" ] && continue
        if jq -e --arg t "$tag" '.inbounds[] | select(.tag==$t)' "$CONFIG_PATH" >/dev/null 2>&1; then
            echo "$i) $name  [已安装，跳过]"
        else
            echo "$i) $name  [端口 $port，卸载于 $removed_at]"
        fi
        arr[$i]="$tag"
        i=$((i+1))
    done
    echo "请选择要恢复的编号(多个用空格分隔，回车取消):"
    read -r input
    [ -z "${input:-}" ] && { info "已取消"; return 0; }
    local to_restore="" n
    for n in $input; do
        tag="${arr[$n]:-}"
        [ -z "$tag" ] && { warn "无效选项: $n"; continue; }
        to_restore="$to_restore $tag"
    done
    [ -z "${to_restore// /}" ] && { warn "没有可恢复的协议"; return 1; }
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "已备份现有配置: ${CONFIG_PATH}.bak"
    local inbound new_port flag cache_keys k v
    for tag in $to_restore; do
        f="$REMOVED_DIR/$tag.json"
        [ ! -f "$f" ] && { warn "备份不存在: $tag"; continue; }
        if jq -e --arg t "$tag" '.inbounds[] | select(.tag==$t)' "$CONFIG_PATH" >/dev/null 2>&1; then
            warn "$(tag_to_name "$tag") 已安装，跳过"
            continue
        fi
        inbound=$(jq -c '.inbound' "$f")
        port=$(echo "$inbound" | jq -r '.listen_port // empty')
        # 端口被占则提示换端口
        if jq -e --argjson p "$port" '.inbounds[] | select(.listen_port == $p)' "$CONFIG_PATH" >/dev/null 2>&1; then
            warn "端口 $port 已被占用，请输入 $(tag_to_name "$tag") 的新端口（留空取消）:"
            read -r new_port
            [ -z "${new_port:-}" ] && { warn "已跳过 $(tag_to_name "$tag")"; continue; }
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                warn "端口无效，跳过"
                continue
            fi
            inbound=$(echo "$inbound" | jq --argjson p "$new_port" '.listen_port = $p')
            port="$new_port"
        fi
        if ! jq --argjson ib "$inbound" '.inbounds += [$ib]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"; then
            err "恢复 $(tag_to_name "$tag") 失败"
            cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            return 1
        fi
        mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
        flag=$(tag_to_flag "$tag")
        eval "$flag=true"
        # 恢复缓存（端口若改了，同步改 *_PORT 键）
        cache_keys=$(jq -r '.cache | keys[]' "$f" 2>/dev/null)
        for k in $cache_keys; do
            v=$(jq -r --arg k "$k" '.cache[$k] // empty' "$f")
            case "$k" in
                *_PORT) v="$port" ;;
            esac
            set_cache_key "$k" "$v"
        done
        rm -f "$f"
        info "已恢复 $(tag_to_name "$tag")（端口 $port，凭据不变）"
    done
    printf 'ENABLE_SS=%s\nENABLE_HY2=%s\nENABLE_TUIC=%s\nENABLE_REALITY=%s\nENABLE_ANYTLS=%s\nENABLE_VLESS_TLS=%s\nENABLE_ANYTLS_TLS=%s\n' \
        "$ENABLE_SS" "$ENABLE_HY2" "$ENABLE_TUIC" "$ENABLE_REALITY" "$ENABLE_ANYTLS" "$ENABLE_VLESS_TLS" "$ENABLE_ANYTLS_TLS" > /etc/sing-box/.protocols
    update_cache_flags
    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置校验失败，已恢复原配置"
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        return 1
    fi
    info "配置校验通过，正在重启服务..."
    service_restart || warn "重启失败，请手动检查"
    sleep 1
    generate_uris || warn "生成 URI 失败"
    info "✅ 恢复完成。"
}

# 切换已安装节点的变体（保留端口与凭据；SS 换加密方式会重新生成密码）
action_switch_variant() {
    read_config || return 1
    if ! command -v jq >/dev/null 2>&1; then
        err "缺少 jq,请先安装 jq"
        return 1
    fi
    info "=== 切换协议变体（端口、密码、密钥尽量保留）==="
    local i=1
    local -a arr kinds
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$i) VLESS Reality → VLESS TLS（端口 $(tag_port vless-in) 不变，UUID 不变）"
        arr[$i]="vless-in"; kinds[$i]="vless-tls"; i=$((i+1))
    fi
    if [ "${ENABLE_VLESS_TLS:-false}" = "true" ]; then
        echo "$i) VLESS TLS → VLESS Reality（端口 $(tag_port vless-tls-in) 不变，UUID 不变）"
        arr[$i]="vless-tls-in"; kinds[$i]="vless-reality"; i=$((i+1))
    fi
    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$i) AnyTLS Reality → AnyTLS TLS（端口 $(tag_port anytls-in) 不变，账号密码不变）"
        arr[$i]="anytls-in"; kinds[$i]="anytls-tls"; i=$((i+1))
    fi
    if [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ]; then
        echo "$i) AnyTLS TLS → AnyTLS Reality（端口 $(tag_port anytls-tls-in) 不变，账号密码不变）"
        arr[$i]="anytls-tls-in"; kinds[$i]="anytls-reality"; i=$((i+1))
    fi
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        if [ "${HY2_OBFS:-none}" = "salamander" ]; then
            echo "$i) HY2：去掉 salamander 混淆（端口、密码不变）"
        else
            echo "$i) HY2：加上 salamander 混淆（端口、密码不变）"
        fi
        arr[$i]="hy2-in"; kinds[$i]="hy2-obfs"; i=$((i+1))
    fi
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$i) TUIC：切换拥塞控制（当前 ${TUIC_CC:-bbr}，端口、账号不变）"
        arr[$i]="tuic-in"; kinds[$i]="tuic-cc"; i=$((i+1))
    fi
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$i) SS：切换加密方式（当前 ${SS_METHOD}，端口不变，密码会重新生成）"
        arr[$i]="ss-in"; kinds[$i]="ss-method"; i=$((i+1))
    fi
    [ "$i" = "1" ] && { warn "没有可切换的协议"; return 1; }
    echo "请选择要切换的编号（回车取消）:"
    read -r input
    [ -z "${input:-}" ] && { info "已取消"; return 0; }
    local from="${arr[$input]:-}" target="${kinds[$input]:-}"
    [ -z "$from" ] && { warn "无效选项: $input"; return 1; }
    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"
    info "已备份现有配置: ${CONFIG_PATH}.bak"

    local port uuid user psk method cc obfs_psk new_inbound
    case "$target" in
        vless-tls)
            ensure_cert || { cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            port=$(tag_port vless-in)
            uuid=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .users[0].uuid // empty' "$CONFIG_PATH")
            new_inbound=$(jq -n --argjson port "$port" --arg uuid "$uuid" \
                '{type:"vless",tag:"vless-tls-in",listen:"::",listen_port:$port,users:[{uuid:$uuid}],tls:{enabled:true,server_name:"www.bing.com",certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}')
            jq --argjson ib "$new_inbound" 'del(.inbounds[] | select(.tag=="vless-in")) | .inbounds += [$ib]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ENABLE_REALITY=false; ENABLE_VLESS_TLS=true
            del_cache_key REALITY_PORT; del_cache_key REALITY_UUID
            # Reality 密钥对保留在缓存里，之后切回 Reality 时复用
            set_cache_key VLESS_TLS_PORT "$port"
            set_cache_key VLESS_TLS_UUID "$uuid"
            info "已切换：VLESS Reality → VLESS TLS（端口 $port，UUID 不变）"
            ;;
        vless-reality)
            ensure_reality_keys || { cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            port=$(tag_port vless-tls-in)
            uuid=$(jq -r '.inbounds[] | select(.tag=="vless-tls-in") | .users[0].uuid // empty' "$CONFIG_PATH")
            new_inbound=$(jq -n --argjson port "$port" --arg uuid "$uuid" --arg sni "$REALITY_SNI" --arg pk "$REALITY_PK" --arg sid "$REALITY_SID" \
                '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}')
            jq --argjson ib "$new_inbound" 'del(.inbounds[] | select(.tag=="vless-tls-in")) | .inbounds += [$ib]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ENABLE_VLESS_TLS=false; ENABLE_REALITY=true
            del_cache_key VLESS_TLS_PORT; del_cache_key VLESS_TLS_UUID
            set_cache_key REALITY_PORT "$port"
            set_cache_key REALITY_UUID "$uuid"
            set_cache_key REALITY_PK "$REALITY_PK"
            set_cache_key REALITY_SID "$REALITY_SID"
            set_cache_key REALITY_PUB "$REALITY_PUB"
            set_cache_key REALITY_SNI "$REALITY_SNI"
            info "已切换：VLESS TLS → VLESS Reality（端口 $port，UUID 不变）"
            ;;
        anytls-tls)
            ensure_cert || { cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            port=$(tag_port anytls-in)
            user=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].name // empty' "$CONFIG_PATH")
            psk=$(jq -r '.inbounds[] | select(.tag=="anytls-in") | .users[0].password // empty' "$CONFIG_PATH")
            new_inbound=$(jq -n --argjson port "$port" --arg user "$user" --arg psk "$psk" \
                '{type:"anytls",tag:"anytls-tls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$psk}],padding_scheme:[],tls:{enabled:true,server_name:"www.bing.com",certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}')
            jq --argjson ib "$new_inbound" 'del(.inbounds[] | select(.tag=="anytls-in")) | .inbounds += [$ib]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ENABLE_ANYTLS=false; ENABLE_ANYTLS_TLS=true
            del_cache_key ANYTLS_PORT; del_cache_key ANYTLS_USER; del_cache_key ANYTLS_PSK
            # Reality 密钥对保留在缓存里，之后切回 Reality 时复用
            set_cache_key ANYTLS_TLS_PORT "$port"
            set_cache_key ANYTLS_TLS_USER "$user"
            set_cache_key ANYTLS_TLS_PSK "$psk"
            info "已切换：AnyTLS Reality → AnyTLS TLS（端口 $port，账号密码不变）"
            ;;
        anytls-reality)
            ensure_reality_keys || { cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            port=$(tag_port anytls-tls-in)
            user=$(jq -r '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].name // empty' "$CONFIG_PATH")
            psk=$(jq -r '.inbounds[] | select(.tag=="anytls-tls-in") | .users[0].password // empty' "$CONFIG_PATH")
            new_inbound=$(jq -n --argjson port "$port" --arg user "$user" --arg psk "$psk" --arg sni "$REALITY_SNI" --arg pk "$REALITY_PK" --arg sid "$REALITY_SID" \
                '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$psk}],padding_scheme:[],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}')
            jq --argjson ib "$new_inbound" 'del(.inbounds[] | select(.tag=="anytls-tls-in")) | .inbounds += [$ib]' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            ENABLE_ANYTLS_TLS=false; ENABLE_ANYTLS=true
            del_cache_key ANYTLS_TLS_PORT; del_cache_key ANYTLS_TLS_USER; del_cache_key ANYTLS_TLS_PSK
            set_cache_key ANYTLS_PORT "$port"
            set_cache_key ANYTLS_USER "$user"
            set_cache_key ANYTLS_PSK "$psk"
            set_cache_key REALITY_PK "$REALITY_PK"
            set_cache_key REALITY_SID "$REALITY_SID"
            set_cache_key REALITY_PUB "$REALITY_PUB"
            set_cache_key REALITY_SNI "$REALITY_SNI"
            info "已切换：AnyTLS TLS → AnyTLS Reality（端口 $port，账号密码不变）"
            ;;
        hy2-obfs)
            if [ "${HY2_OBFS:-none}" = "salamander" ]; then
                jq '(.inbounds[] | select(.tag=="hy2-in")) |= del(.obfs)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                    || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
                mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                set_cache_key HY2_OBFS "none"
                set_cache_key HY2_OBFS_PSK ""
                info "已切换：HY2 去掉 salamander 混淆"
            else
                obfs_psk=$(rand_pass)
                jq --arg obfs_psk "$obfs_psk" '(.inbounds[] | select(.tag=="hy2-in")) |= . + {obfs:{type:"salamander",password:$obfs_psk}}' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                    || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
                mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
                set_cache_key HY2_OBFS "salamander"
                set_cache_key HY2_OBFS_PSK "$obfs_psk"
                info "已切换：HY2 加上 salamander 混淆"
            fi
            ;;
        tuic-cc)
            echo "TUIC 拥塞控制：1) bbr 2) cubic 3) new_reno（当前 ${TUIC_CC:-bbr}）[默认1]:"
            read -r m
            case "${m:-1}" in
                1) cc="bbr" ;;
                2) cc="cubic" ;;
                3) cc="new_reno" ;;
                *) cc="bbr" ;;
            esac
            jq --arg cc "$cc" '(.inbounds[] | select(.tag=="tuic-in")) |= .congestion_control = $cc' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            set_cache_key TUIC_CC "$cc"
            info "已切换：TUIC 拥塞控制 → $cc"
            ;;
        ss-method)
            echo "SS 加密方式：1) 2022-blake3-aes-128-gcm 2) 2022-blake3-aes-256-gcm 3) aes-128-gcm 4) aes-256-gcm 5) chacha20-ietf-poly1305（当前 ${SS_METHOD}）[默认1]:"
            read -r m
            case "${m:-1}" in
                1) method="2022-blake3-aes-128-gcm" ;;
                2) method="2022-blake3-aes-256-gcm" ;;
                3) method="aes-128-gcm" ;;
                4) method="aes-256-gcm" ;;
                5) method="chacha20-ietf-poly1305" ;;
                *) method="2022-blake3-aes-128-gcm" ;;
            esac
            psk=$(rand_pass)
            jq --arg method "$method" --arg psk "$psk" '(.inbounds[] | select(.tag=="ss-in")) |= (.method = $method | .password = $psk)' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" \
                || { err "切换失败"; cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"; return 1; }
            mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
            set_cache_key SS_METHOD "$method"
            set_cache_key SS_PSK "$psk"
            info "已切换：SS 加密方式 → $method（密码已重新生成，客户端需用新链接）"
            ;;
        *)
            err "未知切换目标: $target"
            cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
            return 1
            ;;
    esac
    printf 'ENABLE_SS=%s\nENABLE_HY2=%s\nENABLE_TUIC=%s\nENABLE_REALITY=%s\nENABLE_ANYTLS=%s\nENABLE_VLESS_TLS=%s\nENABLE_ANYTLS_TLS=%s\n' \
        "$ENABLE_SS" "$ENABLE_HY2" "$ENABLE_TUIC" "$ENABLE_REALITY" "$ENABLE_ANYTLS" "$ENABLE_VLESS_TLS" "$ENABLE_ANYTLS_TLS" > /etc/sing-box/.protocols
    update_cache_flags
    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置校验失败，已恢复原配置"
        cp "${CONFIG_PATH}.bak" "$CONFIG_PATH"
        return 1
    fi
    info "配置校验通过，正在重启服务..."
    service_restart || warn "重启失败，请手动检查"
    sleep 1
    action_view_uri || warn "生成 URI 失败"
    info "✅ 切换完成。"
}

show_menu() {
    read_config 2>/dev/null || true
    
    cat <<'MENU'

==========================
 Candies Sing-box 管理面板 (快捷指令candies-sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 构建协议重置选项映射
    declare -g -A MENU_MAP
    local option=4

    # 添加新协议（固定选项）
    MENU_MAP[$option]="add_protocol"
    echo "$option) 添加新协议"
    option=$((option + 1))

    # 卸载协议（固定选项）
    MENU_MAP[$option]="uninstall_protocol"
    echo "$option) 卸载协议（备份凭据，可恢复）"
    option=$((option + 1))

    # 恢复已卸载协议（有备份时才显示）
    if [ -n "$(ls /etc/sing-box/.removed/*.json 2>/dev/null)" ]; then
        MENU_MAP[$option]="restore_protocol"
        echo "$option) 恢复已卸载协议（凭据不变）"
        option=$((option + 1))
    fi

    # 切换协议变体（固定选项）
    MENU_MAP[$option]="switch_variant"
    echo "$option) 切换协议变体（保留端口凭据）"
    option=$((option + 1))
    
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi
    
    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    if [ "${ENABLE_VLESS_TLS:-false}" = "true" ]; then
        echo "$option) 重置 Vless TLS 端口"
        MENU_MAP[$option]="reset_vless_tls"
        option=$((option + 1))
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    if [ "${ENABLE_ANYTLS_TLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS TLS 端口"
        MENU_MAP[$option]="reset_anytls_tls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))
    
    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))
    
    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))
    
    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))
    
    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"
    
    cat <<MENU2
0) 退出
==========================
MENU2
}

# 主循环
while true; do
    show_menu
    read -p "请输入选项: " opt
    
    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi
    
    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                add_protocol) action_add_protocol ;;
                uninstall_protocol) action_uninstall_protocol ;;
                restore_protocol) action_restore_protocol ;;
                switch_variant) action_switch_variant ;;
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_vless_tls) action_reset_vless_tls ;;
                reset_anytls) action_reset_anytls ;;
                reset_anytls_tls) action_reset_anytls_tls ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac
    
    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH"
ln -sf /usr/local/bin/candies-sb /usr/bin/candies-sb
info "✅ 管理面板已创建,可输入 candies-sb 打开管理面板"
