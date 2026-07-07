#!/usr/bin/env sh

set -eu

WORK_DIR="/etc/sing-box-nat"
CONFIG_ENV="$WORK_DIR/config.env"
CONFIG_JSON="$WORK_DIR/config.json"
SB_BIN="$WORK_DIR/sing-box"
CF_BIN="$WORK_DIR/cloudflared"
SB_TGZ="$WORK_DIR/sing-box.tgz"
CF_TMP="$WORK_DIR/cloudflared.tmp"
EXTRACT_DIR="$WORK_DIR/extract"
LOCAL_PORT_DEFAULT="8001"
CLIENT_PORT="443"
WS_PATH="/vmess-argo"

red(){ printf '\033[1;91m%s\033[0m\n' "$1" >&2; }
green(){ printf '\033[1;32m%s\033[0m\n' "$1" >&2; }
yellow(){ printf '\033[1;33m%s\033[0m\n' "$1" >&2; }
plain(){ printf '%s\n' "$1" >&2; }

restore_tty() {
  stty echo >/dev/null 2>&1 || true
}

trap restore_tty EXIT INT TERM

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请使用 root 用户运行。"
    exit 1
  fi
}

ask_default() {
  prompt="$1"
  default="$2"

  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default" >&2
  else
    printf "%s: " "$prompt" >&2
  fi

  read -r value || value=""

  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

ask_required() {
  prompt="$1"
  default="${2:-}"

  while :; do
    value="$(ask_default "$prompt" "$default")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    red "这一项不能为空，请重新填写。"
  done
}

ask_secret() {
  prompt="$1"
  default="${2:-}"

  if [ -n "$default" ]; then
    printf "%s（已保存，直接回车沿用）: " "$prompt" >&2
  else
    printf "%s: " "$prompt" >&2
  fi

  stty -echo >/dev/null 2>&1 || true
  read -r value || value=""
  stty echo >/dev/null 2>&1 || true
  printf '\n' >&2

  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

is_port() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

json_escape() {
  printf '%s' "$1" | awk '
  BEGIN { first = 1 }
  {
    gsub(/\\/,"\\\\")
    gsub(/"/,"\\\"")
    gsub(/\t/,"\\t")
    gsub(/\r/,"\\r")
    if (!first) {
      printf "\\n"
    }
    printf "%s", $0
    first = 0
  }'
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

base64_one_line() {
  base64 | tr -d '\n'
}

detect_os() {
  IS_ALPINE="false"

  if [ -f /etc/alpine-release ]; then
    IS_ALPINE="true"
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SERVICE_MANAGER="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
  else
    SERVICE_MANAGER="none"
  fi

  if [ "$SERVICE_MANAGER" = "none" ]; then
    red "未检测到 systemd 或 openrc，无法自动创建服务。"
    exit 1
  fi
}

detect_arch() {
  raw_arch="$(uname -m)"

  case "$raw_arch" in
    x86_64|amd64)
      SB_ARCH="amd64"
      CF_ARCH="amd64"
      ;;
    aarch64|arm64)
      SB_ARCH="arm64"
      CF_ARCH="arm64"
      ;;
    armv7l|armv7)
      SB_ARCH="armv7"
      CF_ARCH="arm"
      ;;
    i386|i686)
      SB_ARCH="386"
      CF_ARCH="386"
      ;;
    *)
      red "暂不支持当前 CPU 架构：$raw_arch"
      exit 1
      ;;
  esac
}

install_deps() {
  plain "安装基础依赖..."

  if command -v apk >/dev/null 2>&1; then
    apk update
    apk add --no-cache curl tar ca-certificates openssl awk sed grep coreutils >/dev/null
    update-ca-certificates >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates openssl gawk sed grep coreutils >/dev/null
    update-ca-certificates >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl tar ca-certificates openssl gawk sed grep coreutils >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar ca-certificates openssl gawk sed grep coreutils >/dev/null
  else
    red "未检测到支持的包管理器：apk / apt-get / dnf / yum"
    exit 1
  fi
}

load_old_config() {
  if [ -f "$CONFIG_ENV" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_ENV" || true
  fi

  NODE_NAME="${NODE_NAME:-JP-NAT1-Chain}"
  PROXY_TYPE="${PROXY_TYPE:-socks}"
  PROXY_SERVER="${PROXY_SERVER:-isp.decodo.com}"
  PROXY_PORT="${PROXY_PORT:-10002}"
  PROXY_USER="${PROXY_USER:-}"
  PROXY_PASS="${PROXY_PASS:-}"
  ARGO_DOMAIN="${ARGO_DOMAIN:-jp-nat1.example.com}"
  ARGO_TOKEN="${ARGO_TOKEN:-}"
  CLIENT_ADDR="${CLIENT_ADDR:-$ARGO_DOMAIN}"
  LOCAL_PORT="${LOCAL_PORT:-$LOCAL_PORT_DEFAULT}"
  UUID="${UUID:-}"
}

gen_uuid() {
  if [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
  fi
}

collect_config() {
  plain "开始填写安装参数。直接回车可使用方括号内的默认值。"
  plain ""

  NODE_NAME="$(ask_required "请输入节点名称，例如 JP-NAT1-Chain" "$NODE_NAME")"
  PROXY_TYPE="$(ask_required "请输入代理类型，只能填 socks 或 http" "$PROXY_TYPE")"

  case "$PROXY_TYPE" in
    socks|http) ;;
    *)
      red "代理类型只支持 socks 或 http。"
      exit 1
      ;;
  esac

  PROXY_SERVER="$(ask_required "请输入代理服务器，例如 isp.decodo.com" "$PROXY_SERVER")"
  PROXY_PORT="$(ask_required "请输入代理端口，例如 10002" "$PROXY_PORT")"

  if ! is_port "$PROXY_PORT"; then
    red "代理端口不合法：$PROXY_PORT"
    exit 1
  fi

  PROXY_USER="$(ask_default "请输入代理账号，没有就留空" "$PROXY_USER")"
  PROXY_PASS="$(ask_secret "请输入代理密码，没有就直接回车" "$PROXY_PASS")"

  ARGO_DOMAIN="$(ask_required "请输入 Cloudflare Tunnel 固定域名，例如 jp-nat1.chende97.com" "$ARGO_DOMAIN")"
  ARGO_TOKEN="$(ask_secret "请输入 Cloudflare Tunnel token，也就是 eyJ 开头那一整串" "$ARGO_TOKEN")"

  if [ -z "$ARGO_TOKEN" ]; then
    red "Cloudflare Tunnel token 不能为空。"
    exit 1
  fi

  CLIENT_ADDR="$(ask_required "请输入客户端连接地址，通常和固定域名一致" "$ARGO_DOMAIN")"

  plain "客户端连接端口固定使用 443，无需填写。"

  LOCAL_PORT="$(ask_required "填写本机监听端口；Cloudflare Tunnel 公共主机名的服务地址端口必须和这里一致" "$LOCAL_PORT")"

  if ! is_port "$LOCAL_PORT"; then
    red "本机监听端口不合法：$LOCAL_PORT"
    exit 1
  fi

  if [ -z "$UUID" ]; then
    UUID="$(gen_uuid)"
  fi
}

save_config() {
  mkdir -p "$WORK_DIR"

  {
    printf 'NODE_NAME='; shell_quote "$NODE_NAME"; printf '\n'
    printf 'PROXY_TYPE='; shell_quote "$PROXY_TYPE"; printf '\n'
    printf 'PROXY_SERVER='; shell_quote "$PROXY_SERVER"; printf '\n'
    printf 'PROXY_PORT='; shell_quote "$PROXY_PORT"; printf '\n'
    printf 'PROXY_USER='; shell_quote "$PROXY_USER"; printf '\n'
    printf 'PROXY_PASS='; shell_quote "$PROXY_PASS"; printf '\n'
    printf 'ARGO_DOMAIN='; shell_quote "$ARGO_DOMAIN"; printf '\n'
    printf 'ARGO_TOKEN='; shell_quote "$ARGO_TOKEN"; printf '\n'
    printf 'CLIENT_ADDR='; shell_quote "$CLIENT_ADDR"; printf '\n'
    printf 'CLIENT_PORT='; shell_quote "$CLIENT_PORT"; printf '\n'
    printf 'LOCAL_PORT='; shell_quote "$LOCAL_PORT"; printf '\n'
    printf 'WS_PATH='; shell_quote "$WS_PATH"; printf '\n'
    printf 'UUID='; shell_quote "$UUID"; printf '\n'
  } > "$CONFIG_ENV"

  chmod 600 "$CONFIG_ENV"
}

stop_old_services() {
  plain "停止旧服务..."

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl stop sing-box-nat.service >/dev/null 2>&1 || true
    systemctl stop argo-nat.service >/dev/null 2>&1 || true
  elif [ "$SERVICE_MANAGER" = "openrc" ]; then
    rc-service sing-box-nat stop >/dev/null 2>&1 || true
    rc-service argo-nat stop >/dev/null 2>&1 || true
  fi
}

get_latest_singbox_version() {
  release_json="$WORK_DIR/sing-box-release.json"

  curl -fsSL -o "$release_json" "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

  tag="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" | head -n 1)"

  if [ -z "$tag" ]; then
    red "无法获取 sing-box 最新版本号。"
    exit 1
  fi

  SB_TAG="$tag"
  SB_VER="${SB_TAG#v}"
}

download_binaries() {
  plain "下载 sing-box 和 cloudflared..."

  mkdir -p "$WORK_DIR"
  rm -rf "$EXTRACT_DIR"
  rm -f "$SB_TGZ" "$CF_TMP"

  get_latest_singbox_version

  green "检测到 sing-box 最新版本：$SB_TAG"

  if [ "$IS_ALPINE" = "true" ]; then
    SB_PACKAGE="sing-box-${SB_VER}-linux-${SB_ARCH}-musl.tar.gz"
    green "检测到 Alpine，使用 musl 版本：$SB_PACKAGE"
  else
    SB_PACKAGE="sing-box-${SB_VER}-linux-${SB_ARCH}.tar.gz"
    green "检测到非 Alpine，使用普通 Linux 版本：$SB_PACKAGE"
  fi

  SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_TAG}/${SB_PACKAGE}"
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"

  curl -fL --retry 3 --connect-timeout 15 -o "$SB_TGZ" "$SB_URL"

  if [ ! -s "$SB_TGZ" ]; then
    red "sing-box 下载失败：$SB_URL"
    exit 1
  fi

  mkdir -p "$EXTRACT_DIR"
  tar -xzf "$SB_TGZ" -C "$EXTRACT_DIR"

  found_bin="$(find "$EXTRACT_DIR" -type f -name sing-box | head -n 1 || true)"

  if [ -z "$found_bin" ]; then
    red "sing-box 解压后未找到可执行文件。"
    exit 1
  fi

  install -m 755 "$found_bin" "$SB_BIN"

  curl -fL --retry 3 --connect-timeout 15 -o "$CF_TMP" "$CF_URL"

  if [ ! -s "$CF_TMP" ]; then
    red "cloudflared 下载失败：$CF_URL"
    exit 1
  fi

  install -m 755 "$CF_TMP" "$CF_BIN"

  rm -rf "$EXTRACT_DIR"
  rm -f "$SB_TGZ" "$CF_TMP" "$WORK_DIR/sing-box-release.json"

  green "sing-box 和 cloudflared 下载完成。"
}

generate_singbox_config() {
  plain "生成 sing-box 配置..."

  node_name_json="$(json_escape "$NODE_NAME")"
  proxy_server_json="$(json_escape "$PROXY_SERVER")"
  proxy_user_json="$(json_escape "$PROXY_USER")"
  proxy_pass_json="$(json_escape "$PROXY_PASS")"
  uuid_json="$(json_escape "$UUID")"

  if [ "$PROXY_TYPE" = "socks" ]; then
    outbound_type="socks"
    extra_line='    "version": "5",'
  else
    outbound_type="http"
    extra_line=""
  fi

  cat > "$CONFIG_JSON" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": $LOCAL_PORT,
      "users": [
        {
          "name": "$node_name_json",
          "uuid": "$uuid_json",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "$outbound_type",
      "tag": "proxy-out",
      "server": "$proxy_server_json",
      "server_port": $PROXY_PORT,
$extra_line
      "username": "$proxy_user_json",
      "password": "$proxy_pass_json"
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "proxy-out"
  }
}
EOF

  chmod 600 "$CONFIG_JSON"
}

check_singbox_config() {
  plain "检查 sing-box 配置..."

  if ! "$SB_BIN" version >/dev/null 2>&1; then
    red "sing-box 无法运行。"
    red "如果系统是 Alpine，说明 musl 版本仍不兼容当前小鸡。"
    exit 1
  fi

  "$SB_BIN" check -c "$CONFIG_JSON"

  green "sing-box 配置检查通过。"
}

write_systemd_services() {
  cat > /etc/systemd/system/sing-box-nat.service <<EOF
[Unit]
Description=sing-box NAT chain proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONFIG_JSON
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/argo-nat.service <<EOF
[Unit]
Description=Cloudflare Tunnel for NAT chain proxy
After=network-online.target sing-box-nat.service
Wants=network-online.target
Requires=sing-box-nat.service

[Service]
Type=simple
EnvironmentFile=$CONFIG_ENV
ExecStart=$CF_BIN --no-autoupdate tunnel run --token \${ARGO_TOKEN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  chmod 600 /etc/systemd/system/sing-box-nat.service
  chmod 600 /etc/systemd/system/argo-nat.service

  systemctl daemon-reload
  systemctl enable --now sing-box-nat.service
  systemctl enable --now argo-nat.service
}

write_openrc_services() {
  cat > /etc/init.d/sing-box-nat <<EOF
#!/sbin/openrc-run

name="sing-box-nat"
description="sing-box NAT chain proxy"

command="$SB_BIN"
command_args="run -c $CONFIG_JSON"
command_background="yes"
pidfile="/run/sing-box-nat.pid"

depend() {
  need net
}
EOF

  cat > /etc/init.d/argo-nat <<EOF
#!/sbin/openrc-run

name="argo-nat"
description="Cloudflare Tunnel for NAT chain proxy"

CONFIG_ENV="$CONFIG_ENV"

if [ -f "\$CONFIG_ENV" ]; then
  . "\$CONFIG_ENV"
fi

command="$CF_BIN"
command_args="--no-autoupdate tunnel run --token \${ARGO_TOKEN}"
command_background="yes"
pidfile="/run/argo-nat.pid"

depend() {
  need net
  after sing-box-nat
}
EOF

  chmod 755 /etc/init.d/sing-box-nat
  chmod 700 /etc/init.d/argo-nat

  rc-update add sing-box-nat default >/dev/null 2>&1 || true
  rc-update add argo-nat default >/dev/null 2>&1 || true

  rc-service sing-box-nat restart
  sleep 1
  rc-service argo-nat restart
}

write_services() {
  plain "生成并启动系统服务..."

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    write_systemd_services
  elif [ "$SERVICE_MANAGER" = "openrc" ]; then
    write_openrc_services
  else
    red "不支持的服务管理器：$SERVICE_MANAGER"
    exit 1
  fi

  green "服务已启动。"
}

write_natlink() {
  cat > /usr/local/bin/natlink <<'EOF'
#!/usr/bin/env sh

CONFIG_ENV="/etc/sing-box-nat/config.env"

if [ ! -f "$CONFIG_ENV" ]; then
  echo "未找到配置文件：$CONFIG_ENV" >&2
  exit 1
fi

. "$CONFIG_ENV"

json_escape() {
  printf '%s' "$1" | awk '
  BEGIN { first = 1 }
  {
    gsub(/\\/,"\\\\")
    gsub(/"/,"\\\"")
    gsub(/\t/,"\\t")
    gsub(/\r/,"\\r")
    if (!first) {
      printf "\\n"
    }
    printf "%s", $0
    first = 0
  }'
}

base64_one_line() {
  base64 | tr -d '\n'
}

NODE_NAME_JSON="$(json_escape "$NODE_NAME")"
CLIENT_ADDR_JSON="$(json_escape "$CLIENT_ADDR")"
UUID_JSON="$(json_escape "$UUID")"
WS_PATH_JSON="$(json_escape "$WS_PATH")"

VMESS_JSON=$(cat <<JSON
{
  "v": "2",
  "ps": "$NODE_NAME_JSON",
  "add": "$CLIENT_ADDR_JSON",
  "port": "$CLIENT_PORT",
  "id": "$UUID_JSON",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "$CLIENT_ADDR_JSON",
  "path": "$WS_PATH_JSON",
  "tls": "tls",
  "sni": "$CLIENT_ADDR_JSON",
  "alpn": ""
}
JSON
)

printf 'vmess://%s\n' "$(printf '%s' "$VMESS_JSON" | base64_one_line)"
EOF

  chmod 755 /usr/local/bin/natlink
}

show_status() {
  plain ""
  green "安装完成。"
  plain ""
  plain "节点信息："
  plain "节点名称：$NODE_NAME"
  plain "协议：VMess + WebSocket + TLS"
  plain "客户端地址：$CLIENT_ADDR"
  plain "客户端端口：443"
  plain "UUID：$UUID"
  plain "WebSocket Path：$WS_PATH"
  plain ""
  plain "Cloudflare Tunnel 公共主机名必须这样配置："
  plain "公共主机名：$ARGO_DOMAIN"
  plain "类型：HTTP"
  plain "服务地址：http://127.0.0.1:$LOCAL_PORT"
  plain ""
  plain "查看 VMess 分享链接："
  plain "natlink"
  plain ""
  plain "查看服务状态："

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    plain "systemctl status sing-box-nat --no-pager"
    plain "systemctl status argo-nat --no-pager"
  else
    plain "rc-service sing-box-nat status"
    plain "rc-service argo-nat status"
  fi

  plain ""
  green "VMess 分享链接如下："
  natlink
}

main() {
  need_root
  detect_os
  detect_arch

  mkdir -p "$WORK_DIR"

  plain "检测到服务管理器：$SERVICE_MANAGER"
  plain "检测到 CPU 架构：$(uname -m)"
  if [ "$IS_ALPINE" = "true" ]; then
    plain "检测到系统：Alpine，自动使用 sing-box musl 版本。"
  else
    plain "检测到系统：非 Alpine，自动使用 sing-box 普通 Linux 版本。"
  fi

  install_deps
  load_old_config
  collect_config
  save_config
  stop_old_services
  download_binaries
  generate_singbox_config
  check_singbox_config
  write_services
  write_natlink
  show_status
}

main "$@"
