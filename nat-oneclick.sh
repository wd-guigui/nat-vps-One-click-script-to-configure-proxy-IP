#!/usr/bin/env sh
set -eu

# NAT VPS sing-box + Cloudflare Tunnel + Proxy IP one-click installer
# 说明：脚本不会保存到 GitHub 的任何真实账号、密码、token。
# 真实参数只会在 SSH 中交互输入，并保存到小鸡本地 /etc/sing-box-nat/config.env。

WORK_DIR="/etc/sing-box-nat"
CONFIG_ENV="$WORK_DIR/config.env"
LOCAL_PORT_DEFAULT="8001"

red(){ printf '\033[1;91m%s\033[0m\n' "$1"; }
green(){ printf '\033[1;32m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$1"; }

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read -r value
  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi
  printf '%s' "$value"
}

ask_secret() {
  prompt="$1"
  printf "%s: " "$prompt"
  if command -v stty >/dev/null 2>&1; then
    stty -echo || true
    read -r value
    stty echo || true
    printf '\n'
  else
    read -r value
  fi
  printf '%s' "$value"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请先切换到 root 再运行：sudo -i"
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
}

install_pkgs() {
  yellow "安装依赖..."
  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache curl tar gzip ca-certificates coreutils openrc sed grep
    update-ca-certificates || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip ca-certificates coreutils sed grep
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl tar gzip ca-certificates coreutils sed grep
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar gzip ca-certificates coreutils sed grep
  else
    red "无法识别系统包管理器"
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

load_old_config() {
  OLD_NODE_NAME=""
  OLD_PROXY_TYPE="socks"
  OLD_PROXY_SERVER=""
  OLD_PROXY_PORT=""
  OLD_PROXY_USER=""
  OLD_PROXY_PASS=""
  OLD_ARGO_DOMAIN=""
  OLD_ARGO_AUTH=""
  OLD_CFIP=""
  OLD_CFPORT="443"
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
    OLD_CFIP="${CFIP:-}"
    OLD_CFPORT="${CFPORT:-443}"
    OLD_LOCAL_PORT="${LOCAL_PORT:-$LOCAL_PORT_DEFAULT}"
    OLD_UUID="${UUID:-}"
  fi
}

collect_config() {
  yellow "开始填写安装参数。直接回车可使用方括号内的默认值。"
  echo

  HOST_DEFAULT="$(hostname 2>/dev/null || echo nat-vps)"
  NODE_NAME="$(ask '请输入节点名称，例如 JP-NAT1-Chain' "${OLD_NODE_NAME:-$HOST_DEFAULT}")"
  echo
  PROXY_TYPE="$(ask '请输入代理类型，只能填 socks 或 http' "${OLD_PROXY_TYPE:-socks}")"
  echo
  PROXY_SERVER="$(ask '请输入代理服务器，例如 isp.decodo.com' "$OLD_PROXY_SERVER")"
  echo
  PROXY_PORT="$(ask '请输入代理端口，例如 10003' "$OLD_PROXY_PORT")"
  echo
  PROXY_USER="$(ask '请输入代理账号，没有就留空' "$OLD_PROXY_USER")"
  echo
  PROXY_PASS="$(ask_secret '请输入代理密码，没有就直接回车')"
  if [ -z "$PROXY_PASS" ] && [ -n "$OLD_PROXY_PASS" ]; then
    PROXY_PASS="$OLD_PROXY_PASS"
  fi

  echo
  ARGO_DOMAIN="$(ask '请输入 Cloudflare Tunnel 固定域名，例如 jp-nat1.chende97.com' "$OLD_ARGO_DOMAIN")"
  echo
  ARGO_AUTH="$(ask_secret '请输入 Cloudflare Tunnel token，也就是 eyJ 开头那一整串')"
  if [ -z "$ARGO_AUTH" ] && [ -n "$OLD_ARGO_AUTH" ]; then
    ARGO_AUTH="$OLD_ARGO_AUTH"
  fi

  echo
  CFIP="$(ask '请输入客户端连接地址，通常和固定域名一致' "${OLD_CFIP:-$ARGO_DOMAIN}")"
  echo
  CFPORT="$(ask '请输入客户端连接端口' "${OLD_CFPORT:-443}")"
  echo
  LOCAL_PORT="$(ask '请输入本机监听端口，Cloudflare 公共主机名也要用这个端口' "${OLD_LOCAL_PORT:-$LOCAL_PORT_DEFAULT}")"
  echo

  PROXY_TYPE="$(printf '%s' "$PROXY_TYPE" | tr '[:upper:]' '[:lower:]')"
  case "$PROXY_TYPE" in
    socks|socks5) PROXY_TYPE="socks" ;;
    http|https) PROXY_TYPE="http" ;;
    *) red "代理类型只支持 socks 或 http"; exit 1 ;;
  esac

  [ -n "$PROXY_SERVER" ] || { red "代理服务器不能为空"; exit 1; }
  [ -n "$PROXY_PORT" ] || { red "代理端口不能为空"; exit 1; }
  [ -n "$ARGO_DOMAIN" ] || { red "Cloudflare Tunnel 固定域名不能为空"; exit 1; }
  [ -n "$ARGO_AUTH" ] || { red "Cloudflare Tunnel token 不能为空"; exit 1; }
  [ -n "$CFIP" ] || { red "客户端连接地址不能为空"; exit 1; }
  [ -n "$CFPORT" ] || { red "客户端连接端口不能为空"; exit 1; }
  [ -n "$LOCAL_PORT" ] || { red "本机监听端口不能为空"; exit 1; }

  if [ -n "$OLD_UUID" ]; then
    UUID="$OLD_UUID"
  else
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
}

save_config_env() {
  mkdir -p "$WORK_DIR"
  cat > "$CONFIG_ENV" <<EOF2
NODE_NAME='$(printf '%s' "$NODE_NAME" | sed "s/'/'\\\\''/g")'
PROXY_TYPE='$PROXY_TYPE'
PROXY_SERVER='$(printf '%s' "$PROXY_SERVER" | sed "s/'/'\\\\''/g")'
PROXY_PORT='$PROXY_PORT'
PROXY_USER='$(printf '%s' "$PROXY_USER" | sed "s/'/'\\\\''/g")'
PROXY_PASS='$(printf '%s' "$PROXY_PASS" | sed "s/'/'\\\\''/g")'
ARGO_DOMAIN='$(printf '%s' "$ARGO_DOMAIN" | sed "s/'/'\\\\''/g")'
ARGO_AUTH='$(printf '%s' "$ARGO_AUTH" | sed "s/'/'\\\\''/g")'
CFIP='$(printf '%s' "$CFIP" | sed "s/'/'\\\\''/g")'
CFPORT='$CFPORT'
LOCAL_PORT='$LOCAL_PORT'
UUID='$UUID'
EOF2
  chmod 600 "$CONFIG_ENV"
}

download_core() {
  yellow "下载 sing-box 和 cloudflared..."
  mkdir -p "$WORK_DIR"
  cd /tmp

  SB_VER="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
  if [ -z "$SB_VER" ]; then
    red "获取 sing-box 最新版本失败，请检查小鸡能否访问 GitHub"
    exit 1
  fi

  curl -fL --retry 3 -o /tmp/sing-box.tgz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
  rm -rf "/tmp/sing-box-${SB_VER}-linux-${SB_ARCH}"
  tar -xzf /tmp/sing-box.tgz -C /tmp
  install -m 755 "/tmp/sing-box-${SB_VER}-linux-${SB_ARCH}/sing-box" "$WORK_DIR/sing-box"

  curl -fL --retry 3 -o "$WORK_DIR/cloudflared" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  chmod +x "$WORK_DIR/cloudflared"
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

  cat > "$WORK_DIR/config.json" <<EOF2
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
EOF2

  "$WORK_DIR/sing-box" check -c "$WORK_DIR/config.json"
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

make_systemd_services() {
  yellow "创建 systemd 服务..."

  cat > /etc/systemd/system/sing-box-nat.service <<EOF2
[Unit]
Description=sing-box nat chain service
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
EOF2

  cat > /etc/systemd/system/argo-nat.service <<EOF2
[Unit]
Description=Cloudflare Tunnel for sing-box nat chain
After=network.target sing-box-nat.service

[Service]
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/cloudflared tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $ARGO_AUTH
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF2

  systemctl daemon-reload
  systemctl enable sing-box-nat argo-nat >/dev/null
  systemctl restart sing-box-nat
  systemctl restart argo-nat
}

make_openrc_services() {
  yellow "创建 OpenRC 服务..."

  mkdir -p /run/openrc
  touch /run/openrc/softlevel || true

  cat > /etc/init.d/sing-box-nat <<EOF2
#!/sbin/openrc-run

name="sing-box-nat"
description="sing-box nat chain service"

command="$WORK_DIR/sing-box"
command_args="run -c $WORK_DIR/config.json"
command_background="yes"
pidfile="/run/sing-box-nat.pid"
directory="$WORK_DIR"

output_log="$WORK_DIR/sing-box.stdout.log"
error_log="$WORK_DIR/sing-box.stderr.log"

depend() {
  need net
}
EOF2

  chmod +x /etc/init.d/sing-box-nat

  cat > /etc/init.d/argo-nat <<EOF2
#!/sbin/openrc-run

name="argo-nat"
description="Cloudflare Tunnel for sing-box nat chain"

command="$WORK_DIR/cloudflared"
command_args="tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token $ARGO_AUTH"
command_background="yes"
pidfile="/run/argo-nat.pid"
directory="$WORK_DIR"

output_log="$WORK_DIR/argo.stdout.log"
error_log="$WORK_DIR/argo.stderr.log"

depend() {
  need net
  after sing-box-nat
}
EOF2

  chmod +x /etc/init.d/argo-nat

  rc-update add sing-box-nat default >/dev/null 2>&1 || true
  rc-update add argo-nat default >/dev/null 2>&1 || true

  rc-service sing-box-nat start
  sleep 2
  rc-service argo-nat start
}

make_natlink() {
  yellow "创建 natlink 查看节点命令..."

  cat > /usr/local/bin/natlink <<'EOF2'
#!/usr/bin/env sh
set -eu

. /etc/sing-box-nat/config.env

JSON="$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/vmess-argo","tls":"tls","sni":"%s","alpn":"","fp":"chrome","allowInsecure":"false"}' "$NODE_NAME" "$CFIP" "$CFPORT" "$UUID" "$ARGO_DOMAIN" "$ARGO_DOMAIN")"

LINK="vmess://$(printf "%s" "$JSON" | base64 | tr -d '\n')"

echo "$LINK" | tee /etc/sing-box-nat/vmess.txt
EOF2

  chmod +x /usr/local/bin/natlink
}

show_status() {
  echo
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
  echo
  green "安装完成"
  echo
  green "VMess 链接如下："
  natlink
  echo
  yellow "Cloudflare 公共主机名必须这样配置："
  echo "  主机名：$ARGO_DOMAIN"
  echo "  类型：HTTP"
  echo "  服务地址：http://127.0.0.1:$LOCAL_PORT"
  echo
  yellow "常用命令："
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    echo "  查看 sing-box：systemctl status sing-box-nat --no-pager"
    echo "  查看 Tunnel：systemctl status argo-nat --no-pager"
    echo "  重启服务：systemctl restart sing-box-nat argo-nat"
  else
    echo "  查看 sing-box：rc-service sing-box-nat status"
    echo "  查看 Tunnel：rc-service argo-nat status"
    echo "  重启 sing-box：rc-service sing-box-nat restart"
    echo "  重启 Tunnel：rc-service argo-nat restart"
  fi
  echo "  查看节点链接：natlink"
  echo
  yellow "链路结构：客户端 → Cloudflare Tunnel → NAT 小鸡 sing-box → 代理 IP → 目标网站"
}

main() {
  need_root
  install_pkgs
  detect_service_manager
  if [ "$SERVICE_MANAGER" = "unknown" ]; then
    red "未检测到 systemd 或 OpenRC，当前系统不适配"
    exit 1
  fi
  detect_arch
  load_old_config
  collect_config
  save_config_env
  download_core
  stop_old_services
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
