#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="ssh-login-alert"
SCRIPT_VERSION="1.1.0"

# ===== 预填默认值（留空则不预填，也可运行时用环境变量传入）=====
DEFAULT_TG_BOT_TOKEN=""
DEFAULT_TG_CHAT_ID=""
DEFAULT_SERVER_PUBLIC_IP=""
DEFAULT_SERVER_NAME=""

# ===== 颜色输出 =====
if [ -t 1 ]; then
  RED='\033[31m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  BLUE='\033[34m'
  CYAN='\033[36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  BOLD=''
  RESET=''
fi

info() {
  echo -e "${CYAN}ℹ️  $*${RESET}"
}

ok() {
  echo -e "${GREEN}✅ $*${RESET}"
}

warn() {
  echo -e "${YELLOW}⚠️  $*${RESET}"
}

err() {
  echo -e "${RED}❌ $*${RESET}"
}

title() {
  echo
  echo -e "${BOLD}${BLUE}===== $* =====${RESET}"
}

SCRIPT_PATH="/usr/local/bin/ssh-login-alert.sh"
ENV_FILE="/root/.tg-ssh-alert.env"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="session optional pam_exec.so seteuid ${SCRIPT_PATH}"

if [ "$(id -u)" -ne 0 ]; then
  err "请使用 root 执行。"
  exit 1
fi

# ===== 公网 IP 检测函数（安装时调用一次）=====
get_public_ip() {
  local ip=""
  local token=""

  # AWS EC2 IMDSv2
  token="$(curl -fsS --connect-timeout 1 --max-time 2 \
    -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"

  if [ -n "$token" ]; then
    ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
      -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${ip}|AWS Metadata IMDSv2"
      return
    fi
  fi

  # AWS EC2 IMDSv1 fallback
  ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
    "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|AWS Metadata IMDSv1"
    return
  fi

  # GCP Metadata
  ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || true)"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|GCP Metadata"
    return
  fi

  # Azure Metadata
  ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" 2>/dev/null || true)"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|Azure Metadata"
    return
  fi

  # Oracle Cloud Metadata
  ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
    -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/vnics/" 2>/dev/null \
    | grep -m1 -oE "\"publicIp\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" \
    | sed -E "s/.*\"publicIp\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/" || true)"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|Oracle Metadata"
    return
  fi

  # DigitalOcean Metadata
  ip="$(curl -fsS --connect-timeout 1 --max-time 2 \
    "http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address" 2>/dev/null || true)"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|DigitalOcean Metadata"
    return
  fi

  # 外部 API fallback
  for url in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com" \
    "https://ipinfo.io/ip"
  do
    ip="$(curl -4 -fsS --connect-timeout 2 --max-time 3 "$url" 2>/dev/null | tr -d "[:space:]" || true)"

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "${ip}|External API"
      return
    fi
  done

  # 最后兜底
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${ip}|hostname fallback"
    return
  fi

  echo "unknown|unknown"
}

uninstall_common() {
  title "卸载 SSH 登录 Telegram 通知"

  if [ -f "$PAM_FILE" ]; then
    if grep -Fq "$SCRIPT_PATH" "$PAM_FILE"; then
      cp "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
      sed -i "\#${SCRIPT_PATH}#d" "$PAM_FILE"
      ok "已从 PAM 中移除 SSH 登录通知接入。"
    else
      warn "PAM 中未发现 SSH 登录通知接入，跳过。"
    fi
  else
    warn "未找到 $PAM_FILE，跳过 PAM 清理。"
  fi

  if [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH"
    ok "已删除登录通知脚本：$SCRIPT_PATH"
  else
    warn "未找到登录通知脚本，跳过。"
  fi
}

if [ "${1:-}" = "uninstall" ]; then
  uninstall_common

  if [ -f "$ENV_FILE" ]; then
    warn "Telegram 配置文件已保留：$ENV_FILE"
    info "如需彻底删除配置文件，可执行：bash /root/install-ssh-login-tg-alert.sh purge"
  fi

  title "卸载完成"
  exit 0
fi

if [ "${1:-}" = "purge" ]; then
  uninstall_common

  if [ -f "$ENV_FILE" ]; then
    rm -f "$ENV_FILE"
    ok "已删除 Telegram 配置文件：$ENV_FILE"
  else
    warn "未找到 Telegram 配置文件，跳过。"
  fi

  title "彻底卸载完成"
  exit 0
fi

title "SSH 登录 Telegram 通知安装脚本"

# ===== 检测已有配置（二次安装自动带入）=====
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE" 2>/dev/null || true
  if [ -n "${TG_BOT_TOKEN:-}" ] || [ -n "${SERVER_NAME:-}" ]; then
    ok "检测到已有配置，回车使用已有值，输入新值覆盖"
    echo
  fi
fi

# ===== 收集用户输入 =====

# --- Telegram Bot Token ---
CURRENT_DEFAULT="$DEFAULT_TG_BOT_TOKEN"
if [ -n "${TG_BOT_TOKEN:-}" ]; then
  CURRENT_DEFAULT="$TG_BOT_TOKEN"
fi
if [ -n "$CURRENT_DEFAULT" ]; then
  MASKED="${CURRENT_DEFAULT:0:10}..."
  read -rp "Telegram Bot Token [回车使用默认 ${MASKED}]: " INPUT_TOKEN
  TG_BOT_TOKEN="${INPUT_TOKEN:-$CURRENT_DEFAULT}"
else
  read -rp "Telegram Bot Token: " TG_BOT_TOKEN
fi

if [ -z "$TG_BOT_TOKEN" ]; then
  err "Bot Token 不能为空。"
  exit 1
fi

if ! [[ "$TG_BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
  err "Bot Token 格式不正确，应为 数字:英文数字组合"
  exit 1
fi

# --- Telegram Chat ID ---
CURRENT_DEFAULT="$DEFAULT_TG_CHAT_ID"
if [ -n "${TG_CHAT_ID:-}" ]; then
  CURRENT_DEFAULT="$TG_CHAT_ID"
fi
if [ -n "$CURRENT_DEFAULT" ]; then
  read -rp "Telegram Chat ID [回车使用默认 ${CURRENT_DEFAULT}]: " INPUT_CHAT_ID
  TG_CHAT_ID="${INPUT_CHAT_ID:-$CURRENT_DEFAULT}"
else
  read -rp "Telegram Chat ID: " TG_CHAT_ID
fi

if [ -z "$TG_CHAT_ID" ]; then
  err "Chat ID 不能为空。"
  exit 1
fi

# --- 服务器公网 IP ---
read -rp "服务器公网 IP [回车自动检测]: " SERVER_PUBLIC_IP

if [ -n "$SERVER_PUBLIC_IP" ]; then
  if ! [[ "$SERVER_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "服务器公网 IP 格式不正确，请重新执行脚本。"
    exit 1
  fi
  ok "已设置手动公网 IP：$SERVER_PUBLIC_IP"
  IP_SOURCE="Manual config"
fi

# --- VPS 名称 ---
CURRENT_DEFAULT="$DEFAULT_SERVER_NAME"
if [ -n "${SERVER_NAME:-}" ]; then
  CURRENT_DEFAULT="$SERVER_NAME"
fi
if [ -n "$CURRENT_DEFAULT" ]; then
  read -rp "VPS 名称 [回车使用默认 ${CURRENT_DEFAULT}]: " INPUT_NAME
  SERVER_NAME="${INPUT_NAME:-$CURRENT_DEFAULT}"
else
  read -rp "给这台 VPS 取个名字（如: 日本-IIJ-年付）: " SERVER_NAME
fi

if [ -z "$SERVER_NAME" ]; then
  SERVER_NAME="$(hostname -f 2>/dev/null || hostname)"
  warn "未填写名称，将使用系统主机名：$SERVER_NAME"
fi

# ===== 安装 curl =====
title "安装 curl"

if command -v curl >/dev/null 2>&1; then
  ok "curl 已安装，跳过。"
elif command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y curl
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y curl
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl
else
  warn "未检测到 apt/dnf/yum，请手动确认 curl 已安装。"
fi

# ===== 自动检测公网 IP（如果用户留空）=====
if [ -z "${SERVER_PUBLIC_IP:-}" ]; then
  title "检测服务器公网 IP"
  warn "正在检测公网 IP，请稍候..."
  IP_RESULT="$(get_public_ip)"
  SERVER_PUBLIC_IP="${IP_RESULT%%|*}"
  IP_SOURCE="${IP_RESULT#*|}"

  if [ "$SERVER_PUBLIC_IP" = "unknown" ]; then
    SERVER_PUBLIC_IP=""
    warn "公网 IP 检测失败，通知中将不显示 IP。"
  else
    ok "检测到公网 IP：${SERVER_PUBLIC_IP}（来源: ${IP_SOURCE}）"
  fi
fi

# ===== 写入配置文件 =====
title "写入配置文件"

cat > "$ENV_FILE" <<ENV_EOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-}"
SERVER_NAME="${SERVER_NAME}"
IP_SOURCE="${IP_SOURCE:-Manual config}"
ENV_EOF

chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok "配置文件已写入：$ENV_FILE"

# ===== 写入通知脚本 =====
title "写入 SSH 登录通知脚本"

cat > "$SCRIPT_PATH" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/root/.tg-ssh-alert.env"

[ -f "$ENV_FILE" ] || exit 0

OWNER="$(stat -c '%U:%G' "$ENV_FILE" 2>/dev/null || echo unknown)"
if [ "$OWNER" != "root:root" ]; then
  exit 0
fi

source "$ENV_FILE"

[ "${PAM_TYPE:-}" = "open_session" ] || exit 0

# 防抖：sshd 会触发两次 PAM session，10 秒内同一用户不重复通知
THROTTLE_FILE="/tmp/.ssh-alert-throttle-${PAM_USER:-unknown}"
NOW_TS="$(date +%s)"
if [ -f "$THROTTLE_FILE" ]; then
  LAST_TS="$(cat "$THROTTLE_FILE" 2>/dev/null || echo 0)"
  if [ $((NOW_TS - LAST_TS)) -lt 10 ]; then
    exit 0
  fi
fi
echo "$NOW_TS" > "$THROTTLE_FILE"

USER_NAME="${PAM_USER:-unknown}"
REMOTE_HOST="${PAM_RHOST:-unknown}"
TTY_NAME="${PAM_TTY:-unknown}"
LOGIN_TIME="$(date "+%Y-%m-%d %H:%M:%S %Z")"

MESSAGE=$(cat <<EOF
🔐 SSH 登录通知

主机: ${SERVER_NAME}
公网IP: ${SERVER_PUBLIC_IP:-N/A}
用户: ${USER_NAME}
来源IP: ${REMOTE_HOST}
终端: ${TTY_NAME}
时间: ${LOGIN_TIME}
EOF
)

curl -fsS --connect-timeout 3 --max-time 5 \
  -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}" \
  >/dev/null 2>&1 || true

exit 0
SCRIPT_EOF

chown root:root "$SCRIPT_PATH"
chmod 700 "$SCRIPT_PATH"
ok "SSH 登录通知脚本已写入：$SCRIPT_PATH"

# ===== 接入 PAM =====
title "接入 PAM SSH 登录流程"

if [ ! -f "$PAM_FILE" ]; then
  err "未找到 $PAM_FILE，无法自动接入 PAM。"
  exit 1
fi

if grep -Fq "$SCRIPT_PATH" "$PAM_FILE"; then
  warn "PAM 中已存在 ssh-login-alert.sh，跳过重复添加。"
else
  cp "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  echo "$PAM_LINE" >> "$PAM_FILE"
  ok "已添加 PAM 配置。"
fi

# ===== 发送测试消息 =====
title "发送测试 Telegram 消息"

TEST_MESSAGE="✅ SSH 登录通知脚本已安装

主机: ${SERVER_NAME}
版本: ${SCRIPT_VERSION}
时间: $(date "+%Y-%m-%d %H:%M:%S %Z")"

if curl -fsS --connect-timeout 3 --max-time 5 \
  -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${TEST_MESSAGE}" \
  >/dev/null; then
  ok "测试消息发送成功。"
else
  warn "测试消息发送失败，请检查 Bot Token / Chat ID / 网络。"
fi

# ===== 安装结果检查 =====
title "安装结果检查"

if [ -x "$SCRIPT_PATH" ]; then
  ok "登录通知脚本存在且可执行："
  ls -l "$SCRIPT_PATH"
else
  err "登录通知脚本不存在或不可执行：$SCRIPT_PATH"
fi

if grep -Fq "$SCRIPT_PATH" "$PAM_FILE"; then
  echo
  ok "PAM 已接入："
  grep -n "$SCRIPT_PATH" "$PAM_FILE"
else
  echo
  err "PAM 未检测到接入行：$SCRIPT_PATH"
fi

if [ -f "$ENV_FILE" ]; then
  echo
  ok "配置文件存在："
  ls -l "$ENV_FILE"

  OWNER="$(stat -c '%U:%G:%a' "$ENV_FILE" 2>/dev/null || echo unknown)"
  info "配置文件权限：$OWNER"

  if [ -n "${SERVER_NAME:-}" ]; then
    ok "VPS 名称：${SERVER_NAME}"
  fi

  if [ -n "${SERVER_PUBLIC_IP:-}" ]; then
    ok "公网 IP：${SERVER_PUBLIC_IP}（来源: ${IP_SOURCE:-Manual config}）"
  else
    warn "未配置公网 IP。"
  fi
else
  echo
  err "配置文件不存在：$ENV_FILE"
fi

title "安装完成"

ok "请新开一个 SSH 窗口登录测试。"
warn "当前窗口先不要断开。"

echo
info "手动检查命令："
echo "ls -l /usr/local/bin/ssh-login-alert.sh"
echo "grep -n ssh-login-alert.sh /etc/pam.d/sshd"
echo "ls -l /root/.tg-ssh-alert.env"

echo
info "卸载命令（保留配置文件）："
echo "bash /root/install-ssh-login-tg-alert.sh uninstall"

echo
info "彻底卸载命令："
echo "bash /root/install-ssh-login-tg-alert.sh purge"
