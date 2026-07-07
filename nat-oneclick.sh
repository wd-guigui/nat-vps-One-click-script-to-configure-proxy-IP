#!/usr/bin/env sh
set -eu

# NAT VPS sing-box + Cloudflare Tunnel + Proxy IP one-click installer
# 真实账号、密码、token 只在 SSH 中填写，并保存到小鸡本地。
# 不要把真实账号、密码、token 写进 GitHub。

WORK_DIR="/etc/sing-box-nat"
CONFIG_ENV="$WORK_DIR/config.env"
LOCAL_PORT_DEFAULT="8001"
CFPORT="443"

red(){ printf '\033[1;91m%s\033[0m\n' "$1" >&2; }
green(){ printf '\033[1;32m%s\033[0m\n' "$1" >&2; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$1" >&2; }

ask_text() {
  prompt="$1"
  default="${2:-}"

  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi

  read -r value

  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi

  printf '%s' "$value"
}

ask_required() {
  prompt="$1"
  default="${2:-}"

  while :; do
    value="$(ask_text "$prompt" "$default")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    red "这一项不能为空，请重新填写。"
  done
}

ask_secret_keep_old() {
  prompt="$1"
  old_value="${2:-}"

  if [ -n "$old_value" ]; then
    printf "%s（已保存过，直接回车继续使用旧值）: " "$prompt" >&2
  else
    printf "%s: " "$prompt" >&2
  fi

  if command -v stty >/dev/null 2>&1; then
    stty -echo || true
    read -r value
    stty echo || true
    printf '\n' >&2
  else
    read -r value
  fi

  if [ -z "$value" ] && [ -n "$old_value" ]; then
    value="$old_value"
  fi

  printf '%s' "$value"
}

ask_proxy_type() {
  old_type="${1:-socks}"

  case "$old_type" in
    socks|socks5)
      default_choice="1"
      ;;
    http|https)
      default_choice="2"
      ;;
    *)
      default_choice="1"
      ;;
  esac

  while :; do
    echo >&2
    yellow "请选择代理类型："
    echo "  1) SOCKS5" >&2
    echo "  2) HTTP" >&2
    printf "请输入 1 或 2，直接回车使用当前值 [%s]: " "$default_choice" >&2
    read -r choice

    if [ -z "$choice" ]; then
      choice="$default_choice"
    fi

    case "$choice" in
      1)
        printf 'socks'
        return 0
        ;;
      2)
        printf 'http'
        return 0
        ;;
      *)
        red "只能输入 1 或 2。"
        ;;
    esac
  done
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

env_escape() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

write_env_line() {
  key="$1"
  val="$2"
  printf "%s='%s'\n" "$key" "$(env_escape "$val")"
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请先切换到 root 用户后再运行。"
    exit 1
  fi
}

install_pkgs() {
  yellow "安装依赖..."

  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache curl tar gzip ca-certificates coreutils openrc sed grep findutils
    update-ca-certificates || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip ca-certificates coreutils sed grep findutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl tar gzip ca-certificates coreutils sed grep findutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar gzip ca-certificates coreutils sed grep findutils
  else
    red "无法识别系统包管理器。"
    exit 1
  fi
}

detect_service_manager() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SERVICE_MANAGER="systemd"
  elif command -v rc-service >/dev/null 2>&1 || [ -d /etc/init.d ]; then
    SERVICE_MANAGER="openrc"
  else
    SERVICE_MANAGER="unknown"
  fi

  yellow "检测到服务管理器：$SERVICE_MANAGER"

  if [ "$SERVICE_MANAGER" = "unknown" ]; then
    red "未检测到 systemd 或 OpenRC，当前系统暂不适配。"
    exit 1
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      SB_ARCH="amd64"
      CF_ARCH="amd64"
      ;;
    aarch64|arm64)
      SB_ARCH="arm64"
      CF_ARCH="arm64"
      ;;
    i386|i686)
      SB_ARCH="386"
      CF_ARCH="386"
      ;;
    armv7l)
      SB_ARCH="armv7"
      CF_ARCH="arm"
      ;;
    *)
      red "不支持的 CPU 架构：$(uname -m)"
      exit 1
      ;;
  esac

  yellow "检测到 CPU 架构：$(uname -m)"
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
  fi
}

load_old_config() {
  OLD_NODE_NAME=""
  OLD_PROXY_TYPE="socks"
  OLD_PROXY_SERVER=""
  OLD_PROXY_PORT=""
  OLD_PROXY_USER=""
  OLD_PROXY_PASS=""
  OLD_ARGO_DOMAIN=""
  OLD_ARGO_AUTH=""
  OLD_LOCAL_PORT="$LOCAL_PORT_DEFAULT"
  OLD_UUID=""

  if [ -f "$CONFIG_ENV" ]; then
    . "$CONFIG_ENV" || true

    OLD_NODE_NAME="${NODE_NAME:-}"
    OLD_PROXY_TYPE="${PROXY_TYPE:-socks}"
    OLD_PROXY_SERVER="${PROXY_SERVER:-}"
    OLD_PROXY_PORT="${PROXY_PORT:-}"
    OLD_PROXY_USER="${PROXY_USER:-}"
    OLD_PROXY_PASS="${PROXY_PASS:-}"
    OLD_ARGO_DOMAIN="${ARGO_DOMAIN:-}"
    OLD_ARGO_AUTH="${ARGO_AUTH:-}"
    OLD_LOCAL_PORT="${LOCAL_PORT:-$LOCAL_PORT_DEFAULT}"
    OLD_UUID="${UUID:-}"
  fi
}

validate_port() {
  name="$1"
  port="$2"

  case "$port" in
    ''|*[!0-9]*)
      red "$name 必须是数字端口。"
      exit 1
      ;;
  esac

  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    red "$name 必须在 1 到 65535 之间。"
    exit 1
  fi
}

collect_config() {
  echo >&2
  yellow "开始填写安装参数。"
  yellow "直接回车可以使用方括号内已保存的旧值。"
  echo >&2

  NODE_NAME="$(ask_required '填写节点名称' "$OLD_NODE_NAME")"
  PROXY_TYPE="$(ask_proxy_type "$OLD_PROXY_TYPE")"

  echo >&2
  PROXY_SERVER="$(ask_required '填写代理服务器域名或 IP 地址' "$OLD_PROXY_SERVER")"

  echo >&2
  PROXY_PORT="$(ask_required '填写代理端口' "$OLD_PROXY_PORT")"

  echo >&2
  PROXY_USER="$(ask_text '填写代理账号；如果代理已添加 IP 白名单，直接回车；如有代理账号密码，请填写账号' "$OLD_PROXY_USER")"

  echo >&2
  PROXY_PASS="$(ask_secret_keep_old '填写代理密码；如果代理已添加 IP 白名单，直接回车；如有代理账号密码，请填写密码' "$OLD_PROXY_PASS")"

  echo >&2
  ARGO_DOMAIN="$(ask_required '填写 Cloudflare Tunnel 固定域名' "$OLD_ARGO_DOMAIN")"

  echo >&2
  ARGO_AUTH="$(ask_secret_keep_old '填写 Cloudflare Tunnel token，通常是 eyJ 开头的一整串' "$OLD_ARGO_AUTH")"

  echo >&2
  yellow "客户端连接端口固定使用 443，无需填写。"

  echo >&2
  LOCAL_PORT="$(ask_required '填写本机监听端口；Cloudflare Tunnel 公共主机名的服务地址端口必须和这里一致' "${OLD_LOCAL_PORT:-$LOCAL_PORT_DEFAULT}")"

  validate_port "代理端口" "$PROXY_PORT"
  validate_port "本机监听端口" "$LOCAL_PORT"

  if [ -z "$ARGO_AUTH" ]; then
    red "Cloudflare Tunnel token 不能为空。"
    exit 1
  fi

  case "$ARGO_AUTH" in
    eyJ*)
      ;;
    *)
      yellow "提醒：你填写的 Cloudflare Tunnel token 不是 eyJ 开头，请确认是否复制完整。"
      ;;
  esac

  if [ -n "$OLD_UUID" ]; then
    UUID="$OLD_UUID"
  else
    UUID="$(gen_uuid)"
  fi
}

save_config_env() {
  mkdir -p "$WORK_DIR"

  {
    write_env_line NODE_NAME "$NODE_NAME"
    write_env_line PROXY_TYPE "$PROXY_TYPE"
    write_env_line PROXY_SERVER "$PROXY_SERVER"
    write_env_line PROXY_PORT "$PROXY_PORT"
    write_env_line PROXY_USER "$PROXY_USER"
    write_env_line PROXY_PASS "$PROXY_PASS"
    write_env_line ARGO_DOMAIN "$ARGO_DOMAIN"
    write_env_line ARGO_AUTH "$ARGO_AUTH"
    write_env_line CFPORT "$CFPORT"
    write_env_line LOCAL_PORT "$LOCAL_PORT"
    write_env_line UUID "$UUID"
  } > "$CONFIG_ENV"

  chmod 600 "$CONFIG_ENV"
}

stop_old_services() {
  yellow "停止旧服务..."

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl stop sing-box-nat >/dev/null 2>&1 || true
    systemctl stop argo-nat >/dev/null 2>&1 || true
  elif [ "$SERVICE_MANAGER" = "openrc" ]; then
    mkdir -p /run/openrc
    touch /run/openrc/softlevel || true
    rc-service sing-box-nat stop >/dev/null 2>&1 || true
    rc-service argo-nat stop >/dev/null 2>&1 || true
  fi
}

download_core() {
  yellow "下载 sing-box 和 cloudflared..."

  mkdir -p "$WORK_DIR"

  API_FILE="$WORK_DIR/sing-box-release.json"
  SB_TGZ="$WORK_DIR/sing-box.tgz"
  EXTRACT_DIR="$WORK_DIR/sing-box-extract"
  CF_TMP="$WORK_DIR/cloudflared.download"

  rm -f "$API_FILE" "$SB_TGZ" "$CF_TMP"
  rm -rf "$EXTRACT_DIR"

  curl -fL --retry 3 --connect-timeout 20 -o "$API_FILE" \
    "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

  SB_TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$API_FILE" | sed -n '1p')"
  SB_VER="${SB_TAG#v}"

  if [ -z "$SB_VER" ]; then
    red "获取 sing-box 最新版本失败。"
    exit 1
  fi

  yellow "检测到 sing-box 最新版本：v$SB_VER"

  curl -fL --retry 3 --connect-timeout 20 -o "$SB_TGZ" \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"

  if [ ! -s "$SB_TGZ" ]; then
    red "sing-box 下载失败，文件为空或不存在。"
    exit 1
  fi

  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$SB_TGZ" -C "$EXTRACT_DIR"

  SB_BIN="$(find "$EXTRACT_DIR" -type f -name sing-box | sed -n '1p')"

  if [ -z "$SB_BIN" ]; then
    red "sing-box 解压失败，没有找到 sing-box 主程序。"
    exit 1
  fi

  install -m 755 "$SB_BIN" "$WORK_DIR/sing-box"

  curl -fL --retry 3 --connect-timeout 20 -o "$CF_TMP" \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"

  if [ ! -s "$CF_TMP" ]; then
    red "cloudflared 下载失败，文件为空或不存在。"
    exit 1
  fi

  chmod +x "$CF_TMP"
  mv -f "$CF_TMP" "$WORK_DIR/cloudflared"

  rm -f "$API_FILE" "$SB_TGZ"
  rm -rf "$EXTRACT_DIR"

  green "sing-box 和 cloudflared 下载完成。"
}

make_singbox_config() {
  yellow "生成 sing-box 配置..."

  P_SERVER="$(json_escape "$PROXY_SERVER")"
  P_USER="$(json_escape "$PROXY_USER")"
  P_PASS="$(json_escape "$PROXY_PASS")"

  AUTH_FIELDS=""
  if [ -n "$PROXY_USER" ]; then
    AUTH_FIELDS=",\"username\":\"${P_USER}\",\"password\":\"${P_PASS}\""
  fi

  if [ "$PROXY_TYPE" = "socks" ]; then
    OUTBOUND="{\"type\":\"socks\",\"tag\":\"proxy-out\",\"server\":\"${P_SERVER}\",\"server_port\":${PROXY_PORT},\"version\":\"5\"${AUTH_FIELDS},\"network\":\"tcp\"}"
  else
    OUTBOUND="{\"type\":\"http\",\"tag\":\"proxy-out\",\"server\":\"${P_SERVER}\",\"server_port\":${PROXY_PORT}${AUTH_FIELDS}}"
  fi

  cat > "$WORK_DIR/config.json" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "output": "$WORK_DIR/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws-argo-in",
      "listen": "127.0.0.1",
      "listen_port": $LOCAL_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo"
      }
    }
  ],
  "outbounds": [
    $OUTBOUND,
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "final": "proxy-out"
  }
}
EOF

  "$WORK_DIR/sing-box" check -c "$WORK_DIR/config.json"
}

make_systemd_services() {
  yellow "创建 systemd 服务..."

  cat > /etc/systemd/system/sing-box-nat.service <<EOF
[Unit]
Description=sing-box NAT proxy chain
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/sing-box run -c $WORK_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/argo-nat.service <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box NAT proxy chain
After=network.target sing-box-nat.service

[Service]
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $ARGO_AUTH
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable sing-box-nat argo-nat >/dev/null
  systemctl restart sing-box-nat
  sleep 2
  systemctl restart argo-nat
}

make_openrc_services() {
  yellow "创建 OpenRC 服务..."

  mkdir -p /run/openrc
  touch /run/openrc/softlevel || true

  cat > /etc/init.d/sing-box-nat <<EOF
#!/sbin/openrc-run

name="sing-box-nat"
description="sing-box NAT proxy chain"

command="$WORK_DIR/sing-box"
command_args="run -c $WORK_DIR/config.json"
command_background="yes"
pidfile="/run/sing-box-nat.pid"
directory="$WORK_DIR"

output_log="$WORK_DIR/sing-box.stdout.log"
error_log="$WORK_DIR/sing-box.stderr.log"

depend() {
  after net
}
EOF

  chmod +x /etc/init.d/sing-box-nat

  cat > /etc/init.d/argo-nat <<EOF
#!/sbin/openrc-run

name="argo-nat"
description="Cloudflare Tunnel for sing-box NAT proxy chain"

command="$WORK_DIR/cloudflared"
command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $ARGO_AUTH"
command_background="yes"
pidfile="/run/argo-nat.pid"
directory="$WORK_DIR"

output_log="$WORK_DIR/argo.stdout.log"
error_log="$WORK_DIR/argo.stderr.log"

depend() {
  after net
  after sing-box-nat
}
EOF

  chmod +x /etc/init.d/argo-nat

  rc-update add sing-box-nat default >/dev/null 2>&1 || true
  rc-update add argo-nat default >/dev/null 2>&1 || true

  rc-service sing-box-nat restart
  sleep 2
  rc-service argo-nat restart
}

make_natlink() {
  yellow "创建 natlink 查看节点命令..."

  cat > /usr/local/bin/natlink <<'EOF'
#!/usr/bin/env sh
set -eu

. /etc/sing-box-nat/config.env

JSON="$(printf '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess-argo","tls":"tls","sni":"%s","alpn":"","fp":"chrome","allowInsecure":"false"}' "$NODE_NAME" "$ARGO_DOMAIN" "$UUID" "$ARGO_DOMAIN" "$ARGO_DOMAIN")"

LINK="vmess://$(printf "%s" "$JSON" | base64 | tr -d '\n')"

echo "$LINK" | tee /etc/sing-box-nat/vmess.txt
EOF

  chmod +x /usr/local/bin/natlink
}

show_status() {
  echo >&2
  yellow "服务状态："

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl --no-pager --full status sing-box-nat | sed -n '1,8p' || true
    systemctl --no-pager --full status argo-nat | sed -n '1,8p' || true
  elif [ "$SERVICE_MANAGER" = "openrc" ]; then
    rc-service sing-box-nat status || true
    rc-service argo-nat status || true
  fi
}

show_result() {
  echo >&2
  green "安装完成。"
  echo >&2

  green "VMess 链接如下："
  natlink

  echo >&2
  yellow "Cloudflare Tunnel 公共主机名必须这样配置："
  echo "  公共主机名：$ARGO_DOMAIN" >&2
  echo "  服务类型：HTTP" >&2
  echo "  服务地址：http://127.0.0.1:$LOCAL_PORT" >&2
  echo >&2

  yellow "客户端连接信息："
  echo "  地址：$ARGO_DOMAIN" >&2
  echo "  端口：443" >&2
  echo "  传输：WebSocket" >&2
  echo "  路径：/vmess-argo" >&2
  echo "  TLS：开启" >&2
  echo >&2

  yellow "常用命令："

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    echo "  查看 sing-box：systemctl status sing-box-nat --no-pager" >&2
    echo "  查看 Tunnel：systemctl status argo-nat --no-pager" >&2
    echo "  重启服务：systemctl restart sing-box-nat argo-nat" >&2
  else
    echo "  查看 sing-box：rc-service sing-box-nat status" >&2
    echo "  查看 Tunnel：rc-service argo-nat status" >&2
    echo "  重启 sing-box：rc-service sing-box-nat restart" >&2
    echo "  重启 Tunnel：rc-service argo-nat restart" >&2
  fi

  echo "  查看节点链接：natlink" >&2
  echo >&2

  yellow "链路结构：客户端 → Cloudflare Tunnel → NAT 小鸡 sing-box → 代理 IP → 目标网站"
}

main() {
  need_root
  install_pkgs
  detect_service_manager
  detect_arch
  load_old_config
  collect_config
  save_config_env
  stop_old_services
  download_core
  make_singbox_config

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    make_systemd_services
  else
    make_openrc_services
  fi

  make_natlink
  show_status
  show_result
}

main "$@"
