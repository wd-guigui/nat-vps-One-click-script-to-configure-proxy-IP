#!/usr/bin/env sh
set -eu

WORK_DIR="/etc/sing-box-nat"
CONFIG_ENV="$WORK_DIR/config.env"
CONFIG_JSON="$WORK_DIR/config.json"
SB_BIN="$WORK_DIR/sing-box"
CF_BIN="$WORK_DIR/cloudflared"
TMP_DIR="$WORK_DIR/tmp"
SB_RELEASE_JSON="$WORK_DIR/sing-box-release.json"
SB_TGZ="$WORK_DIR/sing-box.tar.gz"
CF_TMP="$WORK_DIR/cloudflared.tmp"

LOCAL_PORT_DEFAULT="8001"
CLIENT_PORT="443"
WS_PATH="/vmess-argo"

red() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }
plain() { printf '%s\n' "$*" >&2; }

restore_tty() {
  stty echo >/dev/null 2>&1 || true
}

trap restore_tty EXIT HUP INT TERM

need_root() {
  if [ "$(id -u)" != "0" ]; then
    red "请使用 root 用户运行。可以先执行：sudo -i"
    exit 1
  fi
}

detect_os() {
  IS_ALPINE="false"
  OS_FAMILY="unknown"

  if [ -f /etc/alpine-release ]; then
    IS_ALPINE="true"
    OS_FAMILY="alpine"
    return 0
  fi

  OS_ID=""
  OS_LIKE=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi

  case " $OS_ID $OS_LIKE " in
    *" debian "*|*" ubuntu "*)
      OS_FAMILY="debian"
      ;;
    *)
      if command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
      else
        red "当前脚本只适配 Alpine、Debian、Ubuntu。"
        exit 1
      fi
      ;;
  esac
}

detect_arch() {
  RAW_ARCH="$(uname -m)"

  case "$RAW_ARCH" in
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
    armv7l|armv7)
      SB_ARCH="armv7"
      CF_ARCH="arm"
      ;;
    *)
      red "暂不支持当前 CPU 架构：$RAW_ARCH"
      exit 1
      ;;
  esac
}

install_deps() {
  plain "安装基础依赖..."

  if [ "$OS_FAMILY" = "alpine" ]; then
    apk update
    apk add --no-cache curl tar gzip ca-certificates openssl sed grep coreutils openrc >/dev/null
    update-ca-certificates >/dev/null 2>&1 || true
    return 0
  fi

  if [ "$OS_FAMILY" = "debian" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip ca-certificates openssl sed grep coreutils >/dev/null
    update-ca-certificates >/dev/null 2>&1 || true
    return 0
  fi

  red "未找到可用包管理器。"
  exit 1
}

detect_service_manager() {
  if [ "$IS_ALPINE" = "true" ]; then
    if command -v rc-service >/dev/null 2>&1 && [ -x /sbin/openrc-run ]; then
      SERVICE_MANAGER="openrc"
      return 0
    fi
    red "检测到 Alpine，但未找到 OpenRC。"
    exit 1
  fi

  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    SERVICE_MANAGER="systemd"
    return 0
  fi

  red "检测到 Debian/Ubuntu，但当前环境没有运行 systemd。"
  exit 1
}

ask_line() {
  prompt="$1"
  printf '%s：' "$prompt" >&2
  IFS= read -r value || value=""
  printf '%s' "$value"
}

ask_required() {
  prompt="$1"
  while :; do
    value="$(ask_line "$prompt")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    red "这一项不能为空，请重新填写。"
  done
}

ask_secret() {
  prompt="$1"
  printf '%s：' "$prompt" >&2
  if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
    stty -echo >/dev/null 2>&1 || true
    IFS= read -r value || value=""
    stty echo >/dev/null 2>&1 || true
    printf '\n' >&2
  else
    IFS= read -r value || value=""
  fi
  printf '%s' "$value"
}

ask_secret_required() {
  prompt="$1"
  while :; do
    value="$(ask_secret "$prompt")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
    red "这一项不能为空，请重新填写。"
  done
}

choose_proxy_type() {
  while :; do
    plain "请选择代理类型："
    plain "1) SOCKS5"
    plain "2) HTTP"
    printf '请输入选项：' >&2
    IFS= read -r choice || choice=""

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
        red "输入错误，只能选择 1 或 2。"
        ;;
    esac
  done
}

is_port() {
  p="$1"
  case "$p" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

ask_port_default() {
  prompt="$1"
  default="$2"

  while :; do
    printf '%s（默认%s）：' "$prompt" "$default" >&2
    IFS= read -r value || value=""
    if [ -z "$value" ]; then
      value="$default"
    fi

    if is_port "$value"; then
      printf '%s' "$value"
      return 0
    fi
    red "端口不合法，请输入 1-65535。"
  done
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
    return 0
  fi

  openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

base64_one_line() {
  base64 | tr -d '\n'
}

collect_config() {
  plain ""
  plain "开始填写安装参数。脚本不会读取旧参数作为默认值，每次运行都会重新询问。"
  plain ""

  NODE_NAME="$(ask_required "请输入节点名称")"
  plain ""
  PROXY_TYPE="$(choose_proxy_type)"
  plain ""
  PROXY_SERVER="$(ask_required "请输入代理服务器")"
  plain ""

  while :; do
    PROXY_PORT="$(ask_required "请输入代理端口")"
    if is_port "$PROXY_PORT"; then
      break
    fi
    red "代理端口不合法，请输入 1-65535。"
  done

  plain ""
  PROXY_USER="$(ask_line "请输入代理账号，没有就留空")"
  plain ""
  PROXY_PASS="$(ask_secret "请输入代理密码，没有就直接回车")"

  if [ -z "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
    red "已填写代理密码，但代理账号为空。请重新运行并填写账号，或账号密码都留空。"
    exit 1
  fi

  plain ""
  ARGO_DOMAIN="$(ask_required "请输入 Cloudflare Tunnel 域名")"
  plain ""
  ARGO_TOKEN="$(ask_secret_required "请输入 Cloudflare Tunnel Token")"
  plain ""
  LOCAL_PORT="$(ask_port_default "请输入本机监听端口" "$LOCAL_PORT_DEFAULT")"

  UUID="$(gen_uuid)"
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
    printf 'CLIENT_PORT='; shell_quote "$CLIENT_PORT"; printf '\n'
    printf 'LOCAL_PORT='; shell_quote "$LOCAL_PORT"; printf '\n'
    printf 'WS_PATH='; shell_quote "$WS_PATH"; printf '\n'
    printf 'UUID='; shell_quote "$UUID"; printf '\n'
  } > "$CONFIG_ENV"

  chmod 600 "$CONFIG_ENV"
}

stop_old_services() {
  plain "停止旧服务..."

  if [ "${SERVICE_MANAGER:-}" = "systemd" ]; then
    systemctl stop argo-nat.service >/dev/null 2>&1 || true
    systemctl stop sing-box-nat.service >/dev/null 2>&1 || true
    return 0
  fi

  if [ "${SERVICE_MANAGER:-}" = "openrc" ]; then
    rc-service argo-nat stop >/dev/null 2>&1 || true
    rc-service sing-box-nat stop >/dev/null 2>&1 || true
  fi
}

get_latest_singbox_version() {
  curl -fsSL --connect-timeout 20 -o "$SB_RELEASE_JSON" "https://api.github.com/repos/SagerNet/sing-box/releases/latest"

  SB_TAG="$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' "$SB_RELEASE_JSON")"
  if [ -z "$SB_TAG" ]; then
    red "无法获取 sing-box 最新版本号，请检查 NAT 小鸡能否访问 GitHub。"
    exit 1
  fi

  SB_VER="${SB_TAG#v}"
}

download_binaries() {
  plain "下载 sing-box 和 cloudflared..."

  mkdir -p "$WORK_DIR"
  rm -rf "$TMP_DIR"
  rm -f "$SB_TGZ" "$CF_TMP" "$SB_RELEASE_JSON"
  mkdir -p "$TMP_DIR"

  get_latest_singbox_version

  if [ "$IS_ALPINE" = "true" ]; then
    SB_SUFFIX="-musl"
    green "检测到 Alpine，自动使用 sing-box musl 版本。"
  else
    SB_SUFFIX=""
    green "检测到 Debian/Ubuntu，自动使用 sing-box glibc 版本。"
  fi

  SB_PACKAGE="sing-box-${SB_VER}-linux-${SB_ARCH}${SB_SUFFIX}.tar.gz"
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_TAG}/${SB_PACKAGE}"
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"

  plain "sing-box：$SB_PACKAGE"
  curl -fL --retry 3 --connect-timeout 20 -o "$SB_TGZ" "$SB_URL"
  if [ ! -s "$SB_TGZ" ]; then
    red "sing-box 下载失败：$SB_URL"
    exit 1
  fi

  tar -xzf "$SB_TGZ" -C "$TMP_DIR"

  EXPECTED_BIN="$TMP_DIR/sing-box-${SB_VER}-linux-${SB_ARCH}${SB_SUFFIX}/sing-box"
  if [ -f "$EXPECTED_BIN" ]; then
    FOUND_SB_BIN="$EXPECTED_BIN"
  else
    FOUND_SB_BIN="$(find "$TMP_DIR" -type f -name sing-box | sed -n '1p')"
  fi

  if [ -z "$FOUND_SB_BIN" ] || [ ! -f "$FOUND_SB_BIN" ]; then
    red "sing-box 解压后未找到可执行文件。"
    exit 1
  fi

  install -m 755 "$FOUND_SB_BIN" "$SB_BIN"

  plain "cloudflared：cloudflared-linux-${CF_ARCH}"
  curl -fL --retry 3 --connect-timeout 20 -o "$CF_TMP" "$CF_URL"
  if [ ! -s "$CF_TMP" ]; then
    red "cloudflared 下载失败：$CF_URL"
    exit 1
  fi

  install -m 755 "$CF_TMP" "$CF_BIN"

  rm -rf "$TMP_DIR"
  rm -f "$SB_TGZ" "$CF_TMP" "$SB_RELEASE_JSON"

  green "sing-box 和 cloudflared 下载完成。"
}

make_outbound_json() {
  proxy_server_json="$(json_escape "$PROXY_SERVER")"
  proxy_user_json="$(json_escape "$PROXY_USER")"
  proxy_pass_json="$(json_escape "$PROXY_PASS")"

  if [ "$PROXY_TYPE" = "socks" ]; then
    if [ -n "$PROXY_USER" ]; then
      cat <<EOF
    {
      "type": "socks",
      "tag": "proxy-out",
      "server": "$proxy_server_json",
      "server_port": $PROXY_PORT,
      "version": "5",
      "username": "$proxy_user_json",
      "password": "$proxy_pass_json",
      "network": "tcp"
    }
EOF
    else
      cat <<EOF
    {
      "type": "socks",
      "tag": "proxy-out",
      "server": "$proxy_server_json",
      "server_port": $PROXY_PORT,
      "version": "5",
      "network": "tcp"
    }
EOF
    fi
    return 0
  fi

  if [ -n "$PROXY_USER" ]; then
    cat <<EOF
    {
      "type": "http",
      "tag": "proxy-out",
      "server": "$proxy_server_json",
      "server_port": $PROXY_PORT,
      "username": "$proxy_user_json",
      "password": "$proxy_pass_json"
    }
EOF
  else
    cat <<EOF
    {
      "type": "http",
      "tag": "proxy-out",
      "server": "$proxy_server_json",
      "server_port": $PROXY_PORT
    }
EOF
  fi
}

generate_singbox_config() {
  plain "生成 sing-box 配置..."

  node_name_json="$(json_escape "$NODE_NAME")"
  uuid_json="$(json_escape "$UUID")"
  ws_path_json="$(json_escape "$WS_PATH")"
  outbound_json="$(make_outbound_json)"

  cat > "$CONFIG_JSON" <<EOF
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
      "tag": "vmess-ws-in",
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
        "path": "$ws_path_json"
      }
    }
  ],
  "outbounds": [
$outbound_json,
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

  chmod 600 "$CONFIG_JSON"
}

check_binaries_and_config() {
  plain "检查 sing-box 配置..."

  if ! "$SB_BIN" version >/dev/null 2>&1; then
    red "sing-box 无法运行。若这是 Alpine，通常表示未下载到 musl 版本。"
    exit 1
  fi

  if ! "$CF_BIN" --version >/dev/null 2>&1; then
    red "cloudflared 无法运行，请检查系统架构是否匹配。"
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
WorkingDirectory=$WORK_DIR
ExecStart=$SB_BIN run -c $CONFIG_JSON
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/argo-nat.service <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box NAT chain proxy
After=network-online.target sing-box-nat.service
Wants=network-online.target
Requires=sing-box-nat.service

[Service]
Type=simple
WorkingDirectory=$WORK_DIR
EnvironmentFile=$CONFIG_ENV
ExecStart=$CF_BIN tunnel --no-autoupdate run --token \${ARGO_TOKEN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/sing-box-nat.service /etc/systemd/system/argo-nat.service

  systemctl daemon-reload
  systemctl enable sing-box-nat.service >/dev/null
  systemctl enable argo-nat.service >/dev/null
  systemctl restart sing-box-nat.service
  sleep 1
  systemctl restart argo-nat.service
}

write_openrc_services() {
  mkdir -p /run/openrc
  touch /run/openrc/softlevel >/dev/null 2>&1 || true

  cat > /etc/init.d/sing-box-nat <<EOF
#!/sbin/openrc-run

name="sing-box-nat"
description="sing-box NAT chain proxy"

command="$SB_BIN"
command_args="run -c $CONFIG_JSON"
command_background="yes"
pidfile="/run/sing-box-nat.pid"
directory="$WORK_DIR"
output_log="$WORK_DIR/sing-box.stdout.log"
error_log="$WORK_DIR/sing-box.stderr.log"

depend() {
  need net
}
EOF

  cat > /etc/init.d/argo-nat <<EOF
#!/sbin/openrc-run

name="argo-nat"
description="Cloudflare Tunnel for sing-box NAT chain proxy"

cfgfile="$CONFIG_ENV"
command="$CF_BIN"
command_background="yes"
pidfile="/run/argo-nat.pid"
directory="$WORK_DIR"
output_log="$WORK_DIR/argo.stdout.log"
error_log="$WORK_DIR/argo.stderr.log"

depend() {
  need net
  after sing-box-nat
}

start_pre() {
  if [ -f "\$cfgfile" ]; then
    . "\$cfgfile"
  fi
  if [ -z "\${ARGO_TOKEN:-}" ]; then
    eerror "ARGO_TOKEN is empty."
    return 1
  fi
  command_args="tunnel --no-autoupdate run --token \${ARGO_TOKEN}"
}
EOF

  chmod 755 /etc/init.d/sing-box-nat /etc/init.d/argo-nat

  rc-update add sing-box-nat default >/dev/null 2>&1 || true
  rc-update add argo-nat default >/dev/null 2>&1 || true
  rc-service sing-box-nat restart
  sleep 1
  rc-service argo-nat restart
}

write_services() {
  plain "创建并启动系统服务..."

  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    write_systemd_services
    return 0
  fi

  if [ "$SERVICE_MANAGER" = "openrc" ]; then
    write_openrc_services
    return 0
  fi

  red "不支持的服务管理器：$SERVICE_MANAGER"
  exit 1
}

write_natlink() {
  cat > /usr/local/bin/natlink <<'EOF'
#!/usr/bin/env sh
set -eu

CONFIG_ENV="/etc/sing-box-nat/config.env"
VMESS_FILE="/etc/sing-box-nat/vmess.txt"

if [ ! -f "$CONFIG_ENV" ]; then
  echo "未找到配置文件：$CONFIG_ENV" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$CONFIG_ENV"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

base64_one_line() {
  base64 | tr -d '\n'
}

node_name_json="$(json_escape "$NODE_NAME")"
argo_domain_json="$(json_escape "$ARGO_DOMAIN")"
uuid_json="$(json_escape "$UUID")"
ws_path_json="$(json_escape "$WS_PATH")"

vmess_json=$(cat <<JSON
{
  "v": "2",
  "ps": "$node_name_json",
  "add": "$argo_domain_json",
  "port": "$CLIENT_PORT",
  "id": "$uuid_json",
  "aid": "0",
  "scy": "auto",
  "net": "ws",
  "type": "none",
  "host": "$argo_domain_json",
  "path": "$ws_path_json",
  "tls": "tls",
  "sni": "$argo_domain_json",
  "alpn": "",
  "fp": "chrome"
}
JSON
)

link="vmess://$(printf '%s' "$vmess_json" | base64_one_line)"
printf '%s\n' "$link" > "$VMESS_FILE"
printf '%s\n' "$link"
EOF

  chmod 755 /usr/local/bin/natlink
}

show_service_hint() {
  plain ""
  plain "常用命令："
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    plain "  查看 sing-box：systemctl status sing-box-nat --no-pager"
    plain "  查看 Tunnel：systemctl status argo-nat --no-pager"
    plain "  重启服务：systemctl restart sing-box-nat argo-nat"
    plain "  查看日志：journalctl -u sing-box-nat -u argo-nat -f"
  else
    plain "  查看 sing-box：rc-service sing-box-nat status"
    plain "  查看 Tunnel：rc-service argo-nat status"
    plain "  重启 sing-box：rc-service sing-box-nat restart"
    plain "  重启 Tunnel：rc-service argo-nat restart"
    plain "  查看日志：tail -f $WORK_DIR/sing-box.stderr.log $WORK_DIR/argo.stderr.log"
  fi
  plain "  查看 VMess 链接：natlink"
}

show_result() {
  plain ""
  green "安装完成。"
  plain ""
  plain "节点信息："
  plain "  节点名称：$NODE_NAME"
  plain "  协议：VMess + WebSocket + TLS"
  plain "  客户端地址：$ARGO_DOMAIN"
  plain "  客户端端口：443"
  plain "  UUID：$UUID"
  plain "  WebSocket Path：$WS_PATH"
  plain ""
  plain "Cloudflare Tunnel 公共主机名必须这样配置："
  plain "  公共主机名：$ARGO_DOMAIN"
  plain "  服务类型：HTTP"
  plain "  服务地址：http://127.0.0.1:$LOCAL_PORT"
  plain ""
  plain "链路结构：客户端 -> Cloudflare Tunnel -> NAT 小鸡 sing-box -> 代理 IP -> 目标网站"
  plain ""
  plain "VMess 分享链接："
  /usr/local/bin/natlink
  show_service_hint
  plain ""
  plain "配置保存位置：$CONFIG_ENV"
  plain "说明：保存配置只用于服务启动和 natlink 输出；下一次运行脚本仍会重新询问全部参数。"
}

main() {
  need_root
  detect_os
  detect_arch
  plain "检测到系统类型：$OS_FAMILY"
  plain "检测到 CPU 架构：$RAW_ARCH"
  install_deps
  detect_service_manager
  plain "检测到服务管理器：$SERVICE_MANAGER"

  collect_config
  save_config
  stop_old_services
  download_binaries
  generate_singbox_config
  check_binaries_and_config
  write_services
  write_natlink
  show_result
}

main "$@"
