#!/usr/bin/env bash
# ============================================================
# dsh-deploy · 一键把 DeepSeek Harness 装上服务器
#
# 用法：
#   PUBLIC_HOST=1.2.3.4 bash install.sh
#   DEEPSEEK_API_KEY=sk-xxx PUBLIC_HOST=1.2.3.4 bash install.sh
#
# 可选环境变量：
#   PUBLIC_HOST        服务器公网 IP（不传则自动探测）
#   PUBLIC_PORT        对外端口，默认 3081
#   DSH_PORT           内部端口，默认 3080
#   NODE_MAJOR         Node 大版本，默认 24（失败回退 22）
#   DEEPSEEK_API_KEY   模型密钥（不传则装完后在网页里填）
#   WITH_AUTH          1 = 额外加一层 Basic Auth，默认 0
#   WORKSPACE          工作区目录，默认 /www/wwwroot/dsh-workspace
# ============================================================
set -uo pipefail

PUBLIC_PORT="${PUBLIC_PORT:-3081}"
DSH_PORT="${DSH_PORT:-3080}"
NODE_MAJOR="${NODE_MAJOR:-24}"
WITH_AUTH="${WITH_AUTH:-0}"
WORKSPACE="${WORKSPACE:-/www/wwwroot/dsh-workspace}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"
POLY_DIR="/www/wwwroot/dsh-polyfill"
CRED_FILE="/www/wwwroot/dsh.credentials.txt"

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m✅ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i 后再来）"

# ── 0. 基本信息 ──────────────────────────────────────────────
if [ -z "${PUBLIC_HOST:-}" ]; then
  PUBLIC_HOST="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$PUBLIC_HOST" ] || die "探测不到公网 IP，请显式传 PUBLIC_HOST=x.x.x.x"
fi
say "公网地址：$PUBLIC_HOST:$PUBLIC_PORT"

PKG=""
command -v apt-get >/dev/null && PKG=apt
[ -z "$PKG" ] && command -v dnf >/dev/null && PKG=dnf
[ -z "$PKG" ] && command -v yum >/dev/null && PKG=yum
[ -n "$PKG" ] || die "只支持 apt / dnf / yum 的系统"

pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf) dnf install -y -q "$@" ;;
    yum) yum install -y -q "$@" ;;
  esac
}

# ── 1. 基础依赖 ──────────────────────────────────────────────
say "安装基础依赖"
pkg_install curl ca-certificates gnupg >/dev/null 2>&1 || warn "基础依赖安装有报错，继续"

# ── 2. swap（内存小的话） ────────────────────────────────────
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MB" -lt 2048 ] && [ ! -f /swapfile ]; then
  say "内存 ${MEM_MB}MB，创建 2G swap"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ── 3. 时区 ──────────────────────────────────────────────────
timedatectl set-timezone Asia/Shanghai 2>/dev/null || ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# ── 4. Node.js ───────────────────────────────────────────────
need_node=1
if command -v node >/dev/null; then
  cur=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  [ "$cur" -ge 22 ] 2>/dev/null && { ok "已有 Node $(node -v)"; need_node=0; }
fi
if [ "$need_node" = "1" ]; then
  say "安装 Node.js $NODE_MAJOR"
  if [ "$PKG" = "apt" ]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1 \
      || curl -fsSL "https://deb.nodesource.com/setup_22.x" | bash - >/dev/null 2>&1
    pkg_install nodejs >/dev/null 2>&1
  else
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
    pkg_install nodejs >/dev/null 2>&1
  fi
fi
command -v node >/dev/null || die "Node.js 安装失败"
ok "Node $(node -v) / npm $(npm -v)"

# ── 5. 安装 dsh ──────────────────────────────────────────────
say "安装 DeepSeek Harness（npm 全局）"
npm i -g @deepseek-ai/dsh --no-audit --no-fund >/dev/null 2>&1 || die "dsh 安装失败"
DSH_BIN="$(command -v dsh)"
[ -x "$DSH_BIN" ] || die "找不到 dsh 可执行文件"
ok "dsh $("$DSH_BIN" --version 2>/dev/null | tail -1)"

# ── 6. 密钥与目录 ────────────────────────────────────────────
mkdir -p "$DSH_HOME/profiles/web" "$WORKSPACE"
if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
  cat > "$DSH_HOME/.credentials.yaml" <<CRED
version: 1
records: {}
refs:
  DEEPSEEK_API_KEY: ${DEEPSEEK_API_KEY}
CRED
  chmod 600 "$DSH_HOME/.credentials.yaml"
  ok "已写入 API Key"
else
  warn "没传 DEEPSEEK_API_KEY，装完后在网页「设置 → 模型」里填"
fi

# ── 7. profile 覆盖层（可选项都在这里） ─────────────────────
if [ ! -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then
  cat > "$DSH_HOME/profiles/web/cordis.patch.yml" <<'PATCH'
# dsh 每次启动都会把这一层叠加在 bundle 之上
# 主题跟随系统
- id: ui-theme
  name: "@deepseek-ai/dsh-client-ui-theme"
  config:
    preference: system
PATCH
fi

# ── 8. systemd 服务 ─────────────────────────────────────────
TOKEN_FILE="/root/dsh-token.txt"
LOG_FILE="/var/log/dsh.log"
say "配置 systemd 服务"
cat > /etc/systemd/system/dsh.service <<SERVICE
[Unit]
Description=DeepSeek Harness Web
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=HOME=/root
Environment=DSH_HOME=$DSH_HOME
Environment=DSH_WORKSPACE=$WORKSPACE
WorkingDirectory=$WORKSPACE
ExecStart=$DSH_BIN web --no-open --host 127.0.0.1 --port $DSH_PORT --public-url http://$PUBLIC_HOST:$PUBLIC_PORT/ --trusted-host $PUBLIC_HOST --trusted-host $PUBLIC_HOST:$PUBLIC_PORT
ExecStartPost=/bin/bash -c "sleep 8; grep -o 'token=[A-Za-z0-9_-]*' $LOG_FILE | tail -1 > $TOKEN_FILE"
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now dsh >/dev/null 2>&1 || warn "dsh 启动命令返回非零，下面看状态"
systemctl restart dsh
sleep 12
systemctl is-active --quiet dsh && ok "dsh 已运行" || { warn "dsh 没起来，最近日志："; tail -20 "$LOG_FILE" 2>/dev/null; }

# ── 9. 老浏览器兼容补丁（关键！） ───────────────────────────
# dsh 前端用到 Chrome 116+ 才有的 API（AbortSignal.any / Promise.withResolvers 等）。
# 手机自带浏览器多是 115 内核，缺这些 API 会直接白屏或一直「重新连接中」。
say "写入 polyfill.js"
mkdir -p "$POLY_DIR"
if [ ! -f "$POLY_DIR/polyfill.js" ]; then
  base64 -d > "$POLY_DIR/polyfill.js" <<'POLY'
LyogZHNoIGxlZ2FjeS1icm93c2VyIHBvbHlmaWxsCiAqIOebruagh++8muiuqSBDaHJvbWUgMTE177yIT1BQTyDnrYnmiYvmnLroh6rluKbmtY/op4jlmajvvInog73ot5EgZHNoIOaWsOeJiOWJjeerr+OAggogKiDlj6rooaUgQVBJ77yM5LiN5pS56KGM5Li677yb5bey5a2Y5Zyo5YiZ5LiA5b6L6Lez6L+H44CCCiAqLwooZnVuY3Rpb24gKCkgewogICd1c2Ugc3RyaWN0JzsKCiAgLy8gLS0tLSBBYm9ydFNpZ25hbC5hbnkgKENocm9tZSAxMTYrKSAtLS0tCiAgaWYgKHR5cGVvZiBBYm9ydFNpZ25hbCAhPT0gJ3VuZGVmaW5lZCcgJiYgIUFib3J0U2lnbmFsLmFueSkgewogICAgQWJvcnRTaWduYWwuYW55ID0gZnVuY3Rpb24gKHNpZ25hbHMpIHsKICAgICAgdmFyIGN0cmwgPSBuZXcgQWJvcnRDb250cm9sbGVyKCk7CiAgICAgIGZ1bmN0aW9uIGFib3J0KHJlYXNvbikgeyBpZiAoIWN0cmwuc2lnbmFsLmFib3J0ZWQpIGN0cmwuYWJvcnQocmVhc29uKTsgfQogICAgICB0cnkgewogICAgICAgIGZvciAodmFyIGkgPSAwOyBpIDwgc2lnbmFscy5sZW5ndGg7IGkrKykgewogICAgICAgICAgdmFyIHMgPSBzaWduYWxzW2ldOwogICAgICAgICAgaWYgKHMuYWJvcnRlZCkgeyBhYm9ydChzLnJlYXNvbik7IGJyZWFrOyB9CiAgICAgICAgICBzLmFkZEV2ZW50TGlzdGVuZXIoJ2Fib3J0JywgZnVuY3Rpb24gKGV2KSB7IGFib3J0KGV2LnRhcmdldC5yZWFzb24pOyB9LCB7IG9uY2U6IHRydWUgfSk7CiAgICAgICAgfQogICAgICB9IGNhdGNoIChlKSB7IC8qIOW/veeVpeepuuWIl+ihqOetieW8guW4uCAqLyB9CiAgICAgIHJldHVybiBjdHJsLnNpZ25hbDsKICAgIH07CiAgfQogIGlmICh0eXBlb2YgQWJvcnRTaWduYWwgIT09ICd1bmRlZmluZWQnICYmICFBYm9ydFNpZ25hbC5wcm90b3R5cGUudGhyb3dJZkFib3J0ZWQpIHsKICAgIEFib3J0U2lnbmFsLnByb3RvdHlwZS50aHJvd0lmQWJvcnRlZCA9IGZ1bmN0aW9uICgpIHsKICAgICAgaWYgKHRoaXMuYWJvcnRlZCkgdGhyb3cgdGhpcy5yZWFzb247CiAgICB9OwogIH0KCiAgLy8gLS0tLSBQcm9taXNlLndpdGhSZXNvbHZlcnMgKENocm9tZSAxMTkrKSAtLS0tCiAgaWYgKCFQcm9taXNlLndpdGhSZXNvbHZlcnMpIHsKICAgIFByb21pc2Uud2l0aFJlc29sdmVycyA9IGZ1bmN0aW9uICgpIHsKICAgICAgdmFyIHJlc29sdmUsIHJlamVjdDsKICAgICAgdmFyIHByb21pc2UgPSBuZXcgUHJvbWlzZShmdW5jdGlvbiAocmVzLCByZWopIHsgcmVzb2x2ZSA9IHJlczsgcmVqZWN0ID0gcmVqOyB9KTsKICAgICAgcmV0dXJuIHsgcHJvbWlzZTogcHJvbWlzZSwgcmVzb2x2ZTogcmVzb2x2ZSwgcmVqZWN0OiByZWplY3QgfTsKICAgIH07CiAgfQoKICAvLyAtLS0tIFByb21pc2UudHJ5IChDaHJvbWUgMTI4KykgLS0tLQogIGlmICghUHJvbWlzZS50cnkpIHsKICAgIFByb21pc2UudHJ5ID0gZnVuY3Rpb24gKGZuKSB7CiAgICAgIHZhciBhcmdzID0gQXJyYXkucHJvdG90eXBlLnNsaWNlLmNhbGwoYXJndW1lbnRzLCAxKTsKICAgICAgcmV0dXJuIG5ldyBQcm9taXNlKGZ1bmN0aW9uIChyZXNvbHZlKSB7IHJlc29sdmUoZm4uYXBwbHkodW5kZWZpbmVkLCBhcmdzKSk7IH0pOwogICAgfTsKICB9CgogIC8vIC0tLS0gT2JqZWN0Lmdyb3VwQnkgLyBNYXAuZ3JvdXBCeSAoQ2hyb21lIDExNyspIC0tLS0KICBpZiAoIU9iamVjdC5ncm91cEJ5KSB7CiAgICBPYmplY3QuZ3JvdXBCeSA9IGZ1bmN0aW9uIChpdGVtcywgY2IpIHsKICAgICAgdmFyIG91dCA9IE9iamVjdC5jcmVhdGUobnVsbCk7CiAgICAgIHZhciBpID0gMDsKICAgICAgZm9yICh2YXIgaXQgb2YgaXRlbXMpIHsKICAgICAgICB2YXIgayA9IFN0cmluZyhjYihpdCwgaSsrKSk7CiAgICAgICAgaWYgKE9iamVjdC5wcm90b3R5cGUuaGFzT3duUHJvcGVydHkuY2FsbChvdXQsIGspKSBvdXRba10ucHVzaChpdCk7CiAgICAgICAgZWxzZSBPYmplY3QuZGVmaW5lUHJvcGVydHkob3V0LCBrLCB7IHZhbHVlOiBbaXRdLCB3cml0YWJsZTogdHJ1ZSwgZW51bWVyYWJsZTogdHJ1ZSwgY29uZmlndXJhYmxlOiB0cnVlIH0pOwogICAgICB9CiAgICAgIHJldHVybiBvdXQ7CiAgICB9OwogIH0KICBpZiAoIU1hcC5ncm91cEJ5KSB7CiAgICBNYXAuZ3JvdXBCeSA9IGZ1bmN0aW9uIChpdGVtcywgY2IpIHsKICAgICAgdmFyIG0gPSBuZXcgTWFwKCk7CiAgICAgIHZhciBpID0gMDsKICAgICAgZm9yICh2YXIgaXQgb2YgaXRlbXMpIHsKICAgICAgICB2YXIgayA9IGNiKGl0LCBpKyspOwogICAgICAgIHZhciBjdXIgPSBtLmdldChrKTsKICAgICAgICBpZiAoY3VyKSBjdXIucHVzaChpdCk7IGVsc2UgbS5zZXQoaywgW2l0XSk7CiAgICAgIH0KICAgICAgcmV0dXJuIG07CiAgICB9OwogIH0KCiAgLy8gLS0tLSBBcnJheS5mcm9tQXN5bmMgKENocm9tZSAxMjErKSAtLS0tCiAgaWYgKCFBcnJheS5mcm9tQXN5bmMpIHsKICAgIEFycmF5LmZyb21Bc3luYyA9IGFzeW5jIGZ1bmN0aW9uIChpdGVtcywgbWFwRm4sIHRoaXNBcmcpIHsKICAgICAgdmFyIG91dCA9IFtdOwogICAgICB2YXIgaSA9IDA7CiAgICAgIGZvciBhd2FpdCAodmFyIHYgb2YgaXRlbXMpIG91dC5wdXNoKG1hcEZuID8gYXdhaXQgbWFwRm4uY2FsbCh0aGlzQXJnLCB2LCBpKyspIDogdik7CiAgICAgIHJldHVybiBvdXQ7CiAgICB9OwogIH0KCiAgLy8gLS0tLSBTZXQg6ZuG5ZCI5pa55rOVIChDaHJvbWUgMTIyKykgLS0tLQogIHZhciBzZXRNZXRob2RzID0gewogICAgdW5pb246IGZ1bmN0aW9uIChvdGhlcikgeyB2YXIgciA9IG5ldyBTZXQodGhpcyk7IGZvciAodmFyIHYgb2Ygb3RoZXIpIHIuYWRkKHYpOyByZXR1cm4gcjsgfSwKICAgIGludGVyc2VjdGlvbjogZnVuY3Rpb24gKG90aGVyKSB7IHZhciByID0gbmV3IFNldCgpOyBmb3IgKHZhciB2IG9mIHRoaXMpIGlmIChvdGhlci5oYXModikpIHIuYWRkKHYpOyByZXR1cm4gcjsgfSwKICAgIGRpZmZlcmVuY2U6IGZ1bmN0aW9uIChvdGhlcikgeyB2YXIgciA9IG5ldyBTZXQoKTsgZm9yICh2YXIgdiBvZiB0aGlzKSBpZiAoIW90aGVyLmhhcyh2KSkgci5hZGQodik7IHJldHVybiByOyB9LAogICAgc3ltbWV0cmljRGlmZmVyZW5jZTogZnVuY3Rpb24gKG90aGVyKSB7CiAgICAgIHZhciByID0gbmV3IFNldCgpOwogICAgICBmb3IgKHZhciB2IG9mIHRoaXMpIGlmICghb3RoZXIuaGFzKHYpKSByLmFkZCh2KTsKICAgICAgZm9yICh2YXIgdyBvZiBvdGhlcikgaWYgKCF0aGlzLmhhcyh3KSkgci5hZGQodyk7CiAgICAgIHJldHVybiByOwogICAgfSwKICAgIGlzU3Vic2V0T2Y6IGZ1bmN0aW9uIChvdGhlcikgeyBmb3IgKHZhciB2IG9mIHRoaXMpIGlmICghb3RoZXIuaGFzKHYpKSByZXR1cm4gZmFsc2U7IHJldHVybiB0cnVlOyB9LAogICAgaXNTdXBlcnNldE9mOiBmdW5jdGlvbiAob3RoZXIpIHsgZm9yICh2YXIgdiBvZiBvdGhlcikgaWYgKCF0aGlzLmhhcyh2KSkgcmV0dXJuIGZhbHNlOyByZXR1cm4gdHJ1ZTsgfSwKICAgIGlzRGlzam9pbnRGcm9tOiBmdW5jdGlvbiAob3RoZXIpIHsgZm9yICh2YXIgdiBvZiB0aGlzKSBpZiAob3RoZXIuaGFzKHYpKSByZXR1cm4gZmFsc2U7IHJldHVybiB0cnVlOyB9CiAgfTsKICBPYmplY3Qua2V5cyhzZXRNZXRob2RzKS5mb3JFYWNoKGZ1bmN0aW9uIChrKSB7CiAgICBpZiAoIVNldC5wcm90b3R5cGVba10pIE9iamVjdC5kZWZpbmVQcm9wZXJ0eShTZXQucHJvdG90eXBlLCBrLCB7IHZhbHVlOiBzZXRNZXRob2RzW2tdLCB3cml0YWJsZTogdHJ1ZSwgY29uZmlndXJhYmxlOiB0cnVlIH0pOwogIH0pOwoKICAvLyAtLS0tIFVSTC5wYXJzZSAvIFVSTC5jYW5QYXJzZSAoQ2hyb21lIDEyMC8xMjYrKSAtLS0tCiAgaWYgKCFVUkwucGFyc2UpIHsKICAgIFVSTC5wYXJzZSA9IGZ1bmN0aW9uICh1cmwsIGJhc2UpIHsKICAgICAgdHJ5IHsgcmV0dXJuIG5ldyBVUkwodXJsLCBiYXNlKTsgfSBjYXRjaCAoZSkgeyByZXR1cm4gbnVsbDsgfQogICAgfTsKICB9CiAgaWYgKCFVUkwuY2FuUGFyc2UpIHsKICAgIFVSTC5jYW5QYXJzZSA9IGZ1bmN0aW9uICh1cmwsIGJhc2UpIHsKICAgICAgdHJ5IHsgbmV3IFVSTCh1cmwsIGJhc2UpOyByZXR1cm4gdHJ1ZTsgfSBjYXRjaCAoZSkgeyByZXR1cm4gZmFsc2U7IH0KICAgIH07CiAgfQoKICAvLyAtLS0tIFJlZ0V4cC5lc2NhcGUgKENocm9tZSAxMzYrKSAtLS0tCiAgaWYgKCFSZWdFeHAuZXNjYXBlKSB7CiAgICBSZWdFeHAuZXNjYXBlID0gZnVuY3Rpb24gKHN0cikgewogICAgICByZXR1cm4gU3RyaW5nKHN0cikucmVwbGFjZSgvW1xcXiQuKis/KClbXF17fXxcL10vZywgJ1xcJCYnKQogICAgICAgIC5yZXBsYWNlKC9eWy1dLywgJ1xceDJkJyk7CiAgICB9OwogIH0KCiAgLy8gLS0tLSBTdHJpbmcucHJvdG90eXBlLnRvV2VsbEZvcm1lZCAvIGlzV2VsbEZvcm1lZCAoQ2hyb21lIDExMSvvvIzogIHnmoTkuZ/msqHmnIkpIC0tLS0KICBpZiAoIVN0cmluZy5wcm90b3R5cGUuaXNXZWxsRm9ybWVkKSB7CiAgICBTdHJpbmcucHJvdG90eXBlLmlzV2VsbEZvcm1lZCA9IGZ1bmN0aW9uICgpIHsKICAgICAgdHJ5IHsgZGVjb2RlVVJJQ29tcG9uZW50KGVuY29kZVVSSUNvbXBvbmVudCh0aGlzKSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIChlKSB7IHJldHVybiBmYWxzZTsgfQogICAgfTsKICB9CgogIC8vIC0tLS0gU3ltYm9sLmRpc3Bvc2UgLyBhc3luY0Rpc3Bvc2Ug5Y2g5L2NIChDaHJvbWUgMTM0KykgLS0tLQogIGlmICh0eXBlb2YgU3ltYm9sLmRpc3Bvc2UgPT09ICd1bmRlZmluZWQnKSB7CiAgICB0cnkgeyBTeW1ib2wuZGlzcG9zZSA9IFN5bWJvbC5mb3IoJ1N5bWJvbC5kaXNwb3NlJyk7IH0gY2F0Y2ggKGUpIHt9CiAgfQogIGlmICh0eXBlb2YgU3ltYm9sLmFzeW5jRGlzcG9zZSA9PT0gJ3VuZGVmaW5lZCcpIHsKICAgIHRyeSB7IFN5bWJvbC5hc3luY0Rpc3Bvc2UgPSBTeW1ib2wuZm9yKCdTeW1ib2wuYXN5bmNEaXNwb3NlJyk7IH0gY2F0Y2ggKGUpIHt9CiAgfQoKICAvLyAtLS0tIEl0ZXJhdG9yIGhlbHBlcnMg5YWc5bqVIChDaHJvbWUgMTIyKykgLS0tLQogIGlmICh0eXBlb2YgSXRlcmF0b3IgIT09ICd1bmRlZmluZWQnICYmICFJdGVyYXRvci5mcm9tKSB7CiAgICBJdGVyYXRvci5mcm9tID0gZnVuY3Rpb24gKG9iaikgewogICAgICBpZiAob2JqICYmIHR5cGVvZiBvYmpbU3ltYm9sLml0ZXJhdG9yXSA9PT0gJ2Z1bmN0aW9uJykgcmV0dXJuIG9ialtTeW1ib2wuaXRlcmF0b3JdKCk7CiAgICAgIGlmIChvYmogJiYgdHlwZW9mIG9iai5uZXh0ID09PSAnZnVuY3Rpb24nKSByZXR1cm4gb2JqOwogICAgICB0aHJvdyBuZXcgVHlwZUVycm9yKCdJdGVyYXRvci5mcm9tOiBub3QgaXRlcmFibGUnKTsKICAgIH07CiAgfQoKICAvLyAtLS0tIE1hcC5wcm90b3R5cGUuZ2V0T3JJbnNlcnRDb21wdXRlZCDlhZzlupUgKOaWsOaPkOahiCkgLS0tLQogIGlmICghTWFwLnByb3RvdHlwZS5nZXRPckluc2VydCkgewogICAgTWFwLnByb3RvdHlwZS5nZXRPckluc2VydCA9IGZ1bmN0aW9uIChrZXksIHZhbHVlKSB7CiAgICAgIGlmICh0aGlzLmhhcyhrZXkpKSByZXR1cm4gdGhpcy5nZXQoa2V5KTsKICAgICAgdGhpcy5zZXQoa2V5LCB2YWx1ZSk7CiAgICAgIHJldHVybiB2YWx1ZTsKICAgIH07CiAgfQogIGlmICghTWFwLnByb3RvdHlwZS5nZXRPckluc2VydENvbXB1dGVkKSB7CiAgICBNYXAucHJvdG90eXBlLmdldE9ySW5zZXJ0Q29tcHV0ZWQgPSBmdW5jdGlvbiAoa2V5LCBmbikgewogICAgICBpZiAodGhpcy5oYXMoa2V5KSkgcmV0dXJuIHRoaXMuZ2V0KGtleSk7CiAgICAgIHZhciB2ID0gZm4oa2V5KTsKICAgICAgdGhpcy5zZXQoa2V5LCB2KTsKICAgICAgcmV0dXJuIHY7CiAgICB9OwogIH0KCiAgdHJ5IHsKICAgIGdsb2JhbFRoaXMuX19EU0hfUE9MWUZJTExfXyA9ICcxLjAnOwogIH0gY2F0Y2ggKGUpIHt9Cn0pKCk7Cg==
POLY
  ok "polyfill.js $(wc -c < "$POLY_DIR/polyfill.js") 字节"
else
  warn "polyfill.js 已存在，跳过"
fi

# ── 10. nginx 反向代理 ──────────────────────────────────────
NGINX_BIN="$(command -v nginx || true)"
if [ -z "$NGINX_BIN" ]; then
  say "安装 nginx"
  pkg_install nginx >/dev/null 2>&1 || warn "nginx 安装失败（可用 SSH 隧道：ssh -L $PUBLIC_PORT:127.0.0.1:$DSH_PORT root@$PUBLIC_HOST）"
  NGINX_BIN="$(command -v nginx || true)"
fi

if [ -n "$NGINX_BIN" ]; then
  AUTH_BLOCK=""
  if [ "$WITH_AUTH" = "1" ]; then
    PASS_REAL="${DSH_PASSWORD:-$(head -c 9 /dev/urandom | base64 | tr -d '/+=' | head -c 12)}"
    if command -v openssl >/dev/null; then
      printf 'dsh:%s\n' "$(openssl passwd -apr1 "$PASS_REAL")" > /www/wwwroot/dsh.htpasswd
    elif command -v htpasswd >/dev/null; then
      htpasswd -bc /www/wwwroot/dsh.htpasswd dsh "$PASS_REAL"
    fi
    chown root:www-data /www/wwwroot/dsh.htpasswd 2>/dev/null || chmod 644 /www/wwwroot/dsh.htpasswd
    chmod 640 /www/wwwroot/dsh.htpasswd 2>/dev/null || true
    AUTH_BLOCK='auth_basic "DeepSeek Harness";
    auth_basic_user_file /www/wwwroot/dsh.htpasswd;'
  fi

  say "写 nginx 站点配置"
  cat > /etc/nginx/conf.d/dsh.conf <<NGINX
server {
    listen $PUBLIC_PORT;
    server_name _;
    client_max_body_size 100m;

    ${AUTH_BLOCK}

    # 老内核兼容补丁（Chrome 115 缺 AbortSignal.any 等）
    location = /polyfill.js {
        alias $POLY_DIR/polyfill.js;
        default_type application/javascript;
        add_header Cache-Control "no-store";
    }

    location / {
        proxy_pass http://127.0.0.1:$DSH_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        # 必须：上游不压缩 HTML，sub_filter 注入才有效
        proxy_set_header Accept-Encoding "";
        sub_filter_once on;
        sub_filter '<head>' '<head><script src="/polyfill.js"></script>';
    }
}
NGINX

  # 避免和默认站点抢 80（一般不影响，但更干净）
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  if "$NGINX_BIN" -t >/dev/null 2>&1; then
    systemctl is-active --quiet nginx || systemctl enable --now nginx >/dev/null 2>&1
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    ok "nginx 已生效（$PUBLIC_PORT → 127.0.0.1:$DSH_PORT）"
  else
    warn "nginx 配置校验失败，执行 nginx -t 看详情"
  fi
fi

# ── 11. 防火墙提示 ──────────────────────────────────────────
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active; then
  ufw allow "$PUBLIC_PORT"/tcp >/dev/null 2>&1 && warn "已在 ufw 放行 $PUBLIC_PORT"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PUBLIC_PORT"/tcp >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1 && warn "已在 firewalld 放行 $PUBLIC_PORT"
fi

# ── 12. 收尾 ────────────────────────────────────────────────
TOKEN_URL=$(grep -o 'token=[A-Za-z0-9_-]*' "$TOKEN_FILE" 2>/dev/null | tail -1)
if [ -n "$TOKEN_URL" ]; then
  LOGIN_URL="http://$PUBLIC_HOST:$PUBLIC_PORT/?$TOKEN_URL"
else
  TOKEN_URL=$(journalctl -u dsh -n 200 --no-pager 2>/dev/null | grep -o 'token=[A-Za-z0-9_-]*' | tail -1)
  LOGIN_URL="http://$PUBLIC_HOST:$PUBLIC_PORT/?${TOKEN_URL:-token=???}"
fi

{
  echo ""
  echo "────────────────────────────────────────────────────────"
  echo " ✅ 部署完成"
  echo ""
  echo " 本机地址   : http://127.0.0.1:$DSH_PORT"
  echo " 对外地址   : http://$PUBLIC_HOST:$PUBLIC_PORT"
  echo " 工作区     : $WORKSPACE"
  echo " 日志       : $LOG_FILE"
  echo ""
  echo " 首次登录（用 token 换 cookie，之后书签根路径即可）："
  echo "   $LOGIN_URL"
  echo ""
  echo " ⚠ dsh 每次重启 token 都会变，最新的一条在："
  echo "   cat $TOKEN_FILE"
  echo "────────────────────────────────────────────────────────"
} | tee "$CRED_FILE"
chmod 600 "$CRED_FILE"
