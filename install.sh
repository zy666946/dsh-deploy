#!/usr/bin/env bash
#
# dsh-deploy —— DeepSeek Harness (dsh) 一键部署脚本（幂等，可重复执行）
#
#   bash install.sh                 # 默认 3080 本地 / 3081 对外 + Basic Auth
#   PUBLIC_PORT=8080 bash install.sh
#   AUTH_USER=dsh AUTH_PASS=你的密码 bash install.sh
#
# 做这些事：
#   1. 检查 Node（>= 22）与 dsh CLI
#   2. 建工作区 + systemd 服务（开机自启、崩溃重启、日志到 /var/log/dsh.log）
#   3. 装 polyfill.js（补 Chrome 116+ 才有的 API，救老内核浏览器）
#   4. 配 nginx 反代 + Basic Auth + polyfill 注入（有 nginx 才做）
#   5. 放宽 WebSocket 心跳（手机浏览器走代理会吞 pong，默认 2s 太苛刻）
#   6. 放行防火墙端口，最后打印访问地址和账号
#
set -euo pipefail

DSH_PORT="${DSH_PORT:-3080}"
PUBLIC_PORT="${PUBLIC_PORT:-3081}"
PUBLIC_HOST="${PUBLIC_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
# 云服务器的 hostname -I 通常是内网地址，直接拿来拼访问链接会打不开
if [[ "$PUBLIC_HOST" =~ ^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
  printf '\033[1;33m[!]\033[0m 检测到内网地址 %s；若要从公网访问，请显式指定：PUBLIC_HOST=你的公网IP bash install.sh\n' "$PUBLIC_HOST"
fi
AUTH_USER="${AUTH_USER:-dsh}"
CRED_FILE="${CRED_FILE:-/www/wwwroot/dsh.credentials.txt}"
if [[ -z "${AUTH_PASS:-}" && -f "$CRED_FILE" ]]; then
  AUTH_PASS="$(sed -n 's/^PASS=//p' "$CRED_FILE" | head -1)"
fi
AUTH_PASS="${AUTH_PASS:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)}"
WORKSPACE="${WORKSPACE:-/www/wwwroot/dsh-workspace}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"
LOG_FILE="${LOG_FILE:-/var/log/dsh.log}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo bash install.sh）"


# ── 0. 基础环境（干净系统也能一把跑完）────────────────────────────────
say "检测系统与包管理器"
PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf      >/dev/null 2>&1; then PKG=dnf
elif command -v yum      >/dev/null 2>&1; then PKG=yum
elif command -v apk      >/dev/null 2>&1; then PKG=apk
fi
[[ -n "$PKG" ]] || warn "未识别的包管理器，基础工具需要你手动装（curl git openssl xz tar）"

pkg_install() {
  case "$PKG" in
    apt) apt-get update -y -qq >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *)   return 0 ;;
  esac
}

if [[ -n "$PKG" && "$PKG" != "apt" && "$PKG" != "apk" ]]; then
  say "启用 EPEL（部分软件源需要）"
  pkg_install epel-release >/dev/null 2>&1 || warn "EPEL 启用失败（可能已启用）"
fi

if [[ -n "$PKG" ]]; then
  say "安装基础工具（curl / git / openssl / xz / tar）"
  case "$PKG" in
    apt) pkg_install curl git openssl xz-utils tar ca-certificates >/dev/null 2>&1 || warn "基础工具安装有警告" ;;
    *)   pkg_install curl git openssl xz tar ca-certificates >/dev/null 2>&1 || warn "基础工具安装有警告" ;;
  esac
fi

# 时区：定时/日志/心跳的安静时段都依赖它
if command -v timedatectl >/dev/null 2>&1; then
  CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  if [[ "$CURRENT_TZ" != "${TZ_NAME:-Asia/Shanghai}" ]]; then
    say "设置时区 ${TZ_NAME:-Asia/Shanghai}（当前 ${CURRENT_TZ:-unknown}）"
    timedatectl set-timezone "${TZ_NAME:-Asia/Shanghai}" 2>/dev/null || warn "时区设置失败，可手动 timedatectl set-timezone"
  fi
fi

# swap：dsh + QQ + 浏览器渲染很容易吃满小内存机器
MEM_MB="$(free -m | awk '/Mem:/{print $2}')"
if ! swapon --show 2>/dev/null | grep -q . && [[ "${MEM_MB:-0}" -lt "${SWAP_BELOW_MB:-4096}" ]]; then
  say "内存 ${MEM_MB}MB，创建 ${SWAP_SIZE:-2G} swap"
  fallocate -l "${SWAP_SIZE:-2G}" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_COUNT:-2048}" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
else
  say "swap 已存在或内存充足，跳过"
fi

# ── 1. Node 与 dsh ─────────────────────────────────────────────────────
say "检查 Node 版本"
NODE_BIN="$(command -v node || true)"

need_node=0
if [[ -z "$NODE_BIN" ]]; then
  need_node=1
else
  NODE_MAJOR="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
  [[ "$NODE_MAJOR" -ge 22 ]] || need_node=1
fi

if [[ "$need_node" == "1" ]]; then
  NODE_VER="${NODE_VER:-v22.14.0}"
  say "安装 Node $NODE_VER（官方二进制到 /usr/local）"
  mkdir -p /usr/local/lib/nodejs
  curl -fsSL "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-linux-x64.tar.xz" -o /tmp/node.tar.xz \
    || die "Node 下载失败，检查网络或改 NODE_VER"
  tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs
  NODE_DIR="/usr/local/lib/nodejs/node-$NODE_VER-linux-x64"
  ln -sf "$NODE_DIR/bin/node" /usr/local/bin/node
  ln -sf "$NODE_DIR/bin/npm"  /usr/local/bin/npm
  ln -sf "$NODE_DIR/bin/npx"  /usr/local/bin/npx
  hash -r
  NODE_BIN="$(command -v node)"
  say "Node 已就绪：$("$NODE_BIN" -v)"
fi

NPM_BIN="$(command -v npm || true)"
[[ -n "$NPM_BIN" ]] || die "没找到 npm"

if command -v dsh >/dev/null 2>&1; then
  say "dsh 已安装：$(dsh --version 2>/dev/null || echo unknown)"
else
  say "安装 @deepseek-ai/dsh"
  "$NPM_BIN" install -g @deepseek-ai/dsh
fi
DSH_BIN="$(command -v dsh)" || die "dsh 安装后仍找不到可执行文件"
NODE_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_DIR:$PATH"

# ── 2. 工作区 ──────────────────────────────────────────────────────────
say "准备工作区 $WORKSPACE"
mkdir -p "$WORKSPACE" "$DSH_HOME"

# ── 3. systemd 服务 ────────────────────────────────────────────────────
say "写 systemd 服务 /etc/systemd/system/dsh.service"
cat > /etc/systemd/system/dsh.service <<SERVICE
[Unit]
Description=DeepSeek Harness (dsh) Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKSPACE
Environment=HOME=/root
Environment=PATH=$NODE_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_OPTIONS=--max-old-space-size=1024
ExecStart=$DSH_BIN web --no-open --host 127.0.0.1 --port $DSH_PORT --public-url http://$PUBLIC_HOST:$PUBLIC_PORT/ --trusted-host $PUBLIC_HOST
Restart=always
RestartSec=5
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
SERVICE

# ── 4. 兼容补丁（老内核浏览器） ────────────────────────────────────────
say "安装 polyfill.js（AbortSignal.any / Promise.withResolvers 等 18 项）"
mkdir -p /www/wwwroot/dsh-polyfill
if [[ ! -f /www/wwwroot/dsh-polyfill/polyfill.js ]]; then
  base64 -d > /www/wwwroot/dsh-polyfill/polyfill.js <<'POLY'
LyogZHNoIGxlZ2FjeS1icm93c2VyIHBvbHlmaWxsCiAqIOebruagh++8muiuqSBDaHJvbWUgMTE177yIT1BQTyDnrYnmiYvmnLroh6rluKbmtY/op4jlmajvvInog73ot5EgZHNoIOaWsOeJiOWJjeerr+OAggogKiDlj6rooaUgQVBJ77yM5LiN5pS56KGM5Li677yb5bey5a2Y5Zyo5YiZ5LiA5b6L6Lez6L+H44CCCiAqLwooZnVuY3Rpb24gKCkgewogICd1c2Ugc3RyaWN0JzsKCiAgLy8gLS0tLSBBYm9ydFNpZ25hbC5hbnkgKENocm9tZSAxMTYrKSAtLS0tCiAgaWYgKHR5cGVvZiBBYm9ydFNpZ25hbCAhPT0gJ3VuZGVmaW5lZCcgJiYgIUFib3J0U2lnbmFsLmFueSkgewogICAgQWJvcnRTaWduYWwuYW55ID0gZnVuY3Rpb24gKHNpZ25hbHMpIHsKICAgICAgdmFyIGN0cmwgPSBuZXcgQWJvcnRDb250cm9sbGVyKCk7CiAgICAgIGZ1bmN0aW9uIGFib3J0KHJlYXNvbikgeyBpZiAoIWN0cmwuc2lnbmFsLmFib3J0ZWQpIGN0cmwuYWJvcnQocmVhc29uKTsgfQogICAgICB0cnkgewogICAgICAgIGZvciAodmFyIGkgPSAwOyBpIDwgc2lnbmFscy5sZW5ndGg7IGkrKykgewogICAgICAgICAgdmFyIHMgPSBzaWduYWxzW2ldOwogICAgICAgICAgaWYgKHMuYWJvcnRlZCkgeyBhYm9ydChzLnJlYXNvbik7IGJyZWFrOyB9CiAgICAgICAgICBzLmFkZEV2ZW50TGlzdGVuZXIoJ2Fib3J0JywgZnVuY3Rpb24gKGV2KSB7IGFib3J0KGV2LnRhcmdldC5yZWFzb24pOyB9LCB7IG9uY2U6IHRydWUgfSk7CiAgICAgICAgfQogICAgICB9IGNhdGNoIChlKSB7IC8qIOW/veeVpeepuuWIl+ihqOetieW8guW4uCAqLyB9CiAgICAgIHJldHVybiBjdHJsLnNpZ25hbDsKICAgIH07CiAgfQogIGlmICh0eXBlb2YgQWJvcnRTaWduYWwgIT09ICd1bmRlZmluZWQnICYmICFBYm9ydFNpZ25hbC5wcm90b3R5cGUudGhyb3dJZkFib3J0ZWQpIHsKICAgIEFib3J0U2lnbmFsLnByb3RvdHlwZS50aHJvd0lmQWJvcnRlZCA9IGZ1bmN0aW9uICgpIHsKICAgICAgaWYgKHRoaXMuYWJvcnRlZCkgdGhyb3cgdGhpcy5yZWFzb247CiAgICB9OwogIH0KCiAgLy8gLS0tLSBQcm9taXNlLndpdGhSZXNvbHZlcnMgKENocm9tZSAxMTkrKSAtLS0tCiAgaWYgKCFQcm9taXNlLndpdGhSZXNvbHZlcnMpIHsKICAgIFByb21pc2Uud2l0aFJlc29sdmVycyA9IGZ1bmN0aW9uICgpIHsKICAgICAgdmFyIHJlc29sdmUsIHJlamVjdDsKICAgICAgdmFyIHByb21pc2UgPSBuZXcgUHJvbWlzZShmdW5jdGlvbiAocmVzLCByZWopIHsgcmVzb2x2ZSA9IHJlczsgcmVqZWN0ID0gcmVqOyB9KTsKICAgICAgcmV0dXJuIHsgcHJvbWlzZTogcHJvbWlzZSwgcmVzb2x2ZTogcmVzb2x2ZSwgcmVqZWN0OiByZWplY3QgfTsKICAgIH07CiAgfQoKICAvLyAtLS0tIFByb21pc2UudHJ5IChDaHJvbWUgMTI4KykgLS0tLQogIGlmICghUHJvbWlzZS50cnkpIHsKICAgIFByb21pc2UudHJ5ID0gZnVuY3Rpb24gKGZuKSB7CiAgICAgIHZhciBhcmdzID0gQXJyYXkucHJvdG90eXBlLnNsaWNlLmNhbGwoYXJndW1lbnRzLCAxKTsKICAgICAgcmV0dXJuIG5ldyBQcm9taXNlKGZ1bmN0aW9uIChyZXNvbHZlKSB7IHJlc29sdmUoZm4uYXBwbHkodW5kZWZpbmVkLCBhcmdzKSk7IH0pOwogICAgfTsKICB9CgogIC8vIC0tLS0gT2JqZWN0Lmdyb3VwQnkgLyBNYXAuZ3JvdXBCeSAoQ2hyb21lIDExNyspIC0tLS0KICBpZiAoIU9iamVjdC5ncm91cEJ5KSB7CiAgICBPYmplY3QuZ3JvdXBCeSA9IGZ1bmN0aW9uIChpdGVtcywgY2IpIHsKICAgICAgdmFyIG91dCA9IE9iamVjdC5jcmVhdGUobnVsbCk7CiAgICAgIHZhciBpID0gMDsKICAgICAgZm9yICh2YXIgaXQgb2YgaXRlbXMpIHsKICAgICAgICB2YXIgayA9IFN0cmluZyhjYihpdCwgaSsrKSk7CiAgICAgICAgaWYgKE9iamVjdC5wcm90b3R5cGUuaGFzT3duUHJvcGVydHkuY2FsbChvdXQsIGspKSBvdXRba10ucHVzaChpdCk7CiAgICAgICAgZWxzZSBPYmplY3QuZGVmaW5lUHJvcGVydHkob3V0LCBrLCB7IHZhbHVlOiBbaXRdLCB3cml0YWJsZTogdHJ1ZSwgZW51bWVyYWJsZTogdHJ1ZSwgY29uZmlndXJhYmxlOiB0cnVlIH0pOwogICAgICB9CiAgICAgIHJldHVybiBvdXQ7CiAgICB9OwogIH0KICBpZiAoIU1hcC5ncm91cEJ5KSB7CiAgICBNYXAuZ3JvdXBCeSA9IGZ1bmN0aW9uIChpdGVtcywgY2IpIHsKICAgICAgdmFyIG0gPSBuZXcgTWFwKCk7CiAgICAgIHZhciBpID0gMDsKICAgICAgZm9yICh2YXIgaXQgb2YgaXRlbXMpIHsKICAgICAgICB2YXIgayA9IGNiKGl0LCBpKyspOwogICAgICAgIHZhciBjdXIgPSBtLmdldChrKTsKICAgICAgICBpZiAoY3VyKSBjdXIucHVzaChpdCk7IGVsc2UgbS5zZXQoaywgW2l0XSk7CiAgICAgIH0KICAgICAgcmV0dXJuIG07CiAgICB9OwogIH0KCiAgLy8gLS0tLSBBcnJheS5mcm9tQXN5bmMgKENocm9tZSAxMjErKSAtLS0tCiAgaWYgKCFBcnJheS5mcm9tQXN5bmMpIHsKICAgIEFycmF5LmZyb21Bc3luYyA9IGFzeW5jIGZ1bmN0aW9uIChpdGVtcywgbWFwRm4sIHRoaXNBcmcpIHsKICAgICAgdmFyIG91dCA9IFtdOwogICAgICB2YXIgaSA9IDA7CiAgICAgIGZvciBhd2FpdCAodmFyIHYgb2YgaXRlbXMpIG91dC5wdXNoKG1hcEZuID8gYXdhaXQgbWFwRm4uY2FsbCh0aGlzQXJnLCB2LCBpKyspIDogdik7CiAgICAgIHJldHVybiBvdXQ7CiAgICB9OwogIH0KCiAgLy8gLS0tLSBTZXQg6ZuG5ZCI5pa55rOVIChDaHJvbWUgMTIyKykgLS0tLQogIHZhciBzZXRNZXRob2RzID0gewogICAgdW5pb246IGZ1bmN0aW9uIChvdGhlcikgeyB2YXIgciA9IG5ldyBTZXQodGhpcyk7IGZvciAodmFyIHYgb2Ygb3RoZXIpIHIuYWRkKHYpOyByZXR1cm4gcjsgfSwKICAgIGludGVyc2VjdGlvbjogZnVuY3Rpb24gKG90aGVyKSB7IHZhciByID0gbmV3IFNldCgpOyBmb3IgKHZhciB2IG9mIHRoaXMpIGlmIChvdGhlci5oYXModikpIHIuYWRkKHYpOyByZXR1cm4gcjsgfSwKICAgIGRpZmZlcmVuY2U6IGZ1bmN0aW9uIChvdGhlcikgeyB2YXIgciA9IG5ldyBTZXQoKTsgZm9yICh2YXIgdiBvZiB0aGlzKSBpZiAoIW90aGVyLmhhcyh2KSkgci5hZGQodik7IHJldHVybiByOyB9LAogICAgc3ltbWV0cmljRGlmZmVyZW5jZTogZnVuY3Rpb24gKG90aGVyKSB7CiAgICAgIHZhciByID0gbmV3IFNldCgpOwogICAgICBmb3IgKHZhciB2IG9mIHRoaXMpIGlmICghb3RoZXIuaGFzKHYpKSByLmFkZCh2KTsKICAgICAgZm9yICh2YXIgdyBvZiBvdGhlcikgaWYgKCF0aGlzLmhhcyh3KSkgci5hZGQodyk7CiAgICAgIHJldHVybiByOwogICAgfSwKICAgIGlzU3Vic2V0T2Y6IGZ1bmN0aW9uIChvdGhlcikgeyBmb3IgKHZhciB2IG9mIHRoaXMpIGlmICghb3RoZXIuaGFzKHYpKSByZXR1cm4gZmFsc2U7IHJldHVybiB0cnVlOyB9LAogICAgaXNTdXBlcnNldE9mOiBmdW5jdGlvbiAob3RoZXIpIHsgZm9yICh2YXIgdiBvZiBvdGhlcikgaWYgKCF0aGlzLmhhcyh2KSkgcmV0dXJuIGZhbHNlOyByZXR1cm4gdHJ1ZTsgfSwKICAgIGlzRGlzam9pbnRGcm9tOiBmdW5jdGlvbiAob3RoZXIpIHsgZm9yICh2YXIgdiBvZiB0aGlzKSBpZiAob3RoZXIuaGFzKHYpKSByZXR1cm4gZmFsc2U7IHJldHVybiB0cnVlOyB9CiAgfTsKICBPYmplY3Qua2V5cyhzZXRNZXRob2RzKS5mb3JFYWNoKGZ1bmN0aW9uIChrKSB7CiAgICBpZiAoIVNldC5wcm90b3R5cGVba10pIE9iamVjdC5kZWZpbmVQcm9wZXJ0eShTZXQucHJvdG90eXBlLCBrLCB7IHZhbHVlOiBzZXRNZXRob2RzW2tdLCB3cml0YWJsZTogdHJ1ZSwgY29uZmlndXJhYmxlOiB0cnVlIH0pOwogIH0pOwoKICAvLyAtLS0tIFVSTC5wYXJzZSAvIFVSTC5jYW5QYXJzZSAoQ2hyb21lIDEyMC8xMjYrKSAtLS0tCiAgaWYgKCFVUkwucGFyc2UpIHsKICAgIFVSTC5wYXJzZSA9IGZ1bmN0aW9uICh1cmwsIGJhc2UpIHsKICAgICAgdHJ5IHsgcmV0dXJuIG5ldyBVUkwodXJsLCBiYXNlKTsgfSBjYXRjaCAoZSkgeyByZXR1cm4gbnVsbDsgfQogICAgfTsKICB9CiAgaWYgKCFVUkwuY2FuUGFyc2UpIHsKICAgIFVSTC5jYW5QYXJzZSA9IGZ1bmN0aW9uICh1cmwsIGJhc2UpIHsKICAgICAgdHJ5IHsgbmV3IFVSTCh1cmwsIGJhc2UpOyByZXR1cm4gdHJ1ZTsgfSBjYXRjaCAoZSkgeyByZXR1cm4gZmFsc2U7IH0KICAgIH07CiAgfQoKICAvLyAtLS0tIFJlZ0V4cC5lc2NhcGUgKENocm9tZSAxMzYrKSAtLS0tCiAgaWYgKCFSZWdFeHAuZXNjYXBlKSB7CiAgICBSZWdFeHAuZXNjYXBlID0gZnVuY3Rpb24gKHN0cikgewogICAgICByZXR1cm4gU3RyaW5nKHN0cikucmVwbGFjZSgvW1xcXiQuKis/KClbXF17fXxcL10vZywgJ1xcJCYnKQogICAgICAgIC5yZXBsYWNlKC9eWy1dLywgJ1xceDJkJyk7CiAgICB9OwogIH0KCiAgLy8gLS0tLSBTdHJpbmcucHJvdG90eXBlLnRvV2VsbEZvcm1lZCAvIGlzV2VsbEZvcm1lZCAoQ2hyb21lIDExMSvvvIzogIHnmoTkuZ/msqHmnIkpIC0tLS0KICBpZiAoIVN0cmluZy5wcm90b3R5cGUuaXNXZWxsRm9ybWVkKSB7CiAgICBTdHJpbmcucHJvdG90eXBlLmlzV2VsbEZvcm1lZCA9IGZ1bmN0aW9uICgpIHsKICAgICAgdHJ5IHsgZGVjb2RlVVJJQ29tcG9uZW50KGVuY29kZVVSSUNvbXBvbmVudCh0aGlzKSk7IHJldHVybiB0cnVlOyB9IGNhdGNoIChlKSB7IHJldHVybiBmYWxzZTsgfQogICAgfTsKICB9CgogIC8vIC0tLS0gU3ltYm9sLmRpc3Bvc2UgLyBhc3luY0Rpc3Bvc2Ug5Y2g5L2NIChDaHJvbWUgMTM0KykgLS0tLQogIGlmICh0eXBlb2YgU3ltYm9sLmRpc3Bvc2UgPT09ICd1bmRlZmluZWQnKSB7CiAgICB0cnkgeyBTeW1ib2wuZGlzcG9zZSA9IFN5bWJvbC5mb3IoJ1N5bWJvbC5kaXNwb3NlJyk7IH0gY2F0Y2ggKGUpIHt9CiAgfQogIGlmICh0eXBlb2YgU3ltYm9sLmFzeW5jRGlzcG9zZSA9PT0gJ3VuZGVmaW5lZCcpIHsKICAgIHRyeSB7IFN5bWJvbC5hc3luY0Rpc3Bvc2UgPSBTeW1ib2wuZm9yKCdTeW1ib2wuYXN5bmNEaXNwb3NlJyk7IH0gY2F0Y2ggKGUpIHt9CiAgfQoKICAvLyAtLS0tIEl0ZXJhdG9yIGhlbHBlcnMg5YWc5bqVIChDaHJvbWUgMTIyKykgLS0tLQogIGlmICh0eXBlb2YgSXRlcmF0b3IgIT09ICd1bmRlZmluZWQnICYmICFJdGVyYXRvci5mcm9tKSB7CiAgICBJdGVyYXRvci5mcm9tID0gZnVuY3Rpb24gKG9iaikgewogICAgICBpZiAob2JqICYmIHR5cGVvZiBvYmpbU3ltYm9sLml0ZXJhdG9yXSA9PT0gJ2Z1bmN0aW9uJykgcmV0dXJuIG9ialtTeW1ib2wuaXRlcmF0b3JdKCk7CiAgICAgIGlmIChvYmogJiYgdHlwZW9mIG9iai5uZXh0ID09PSAnZnVuY3Rpb24nKSByZXR1cm4gb2JqOwogICAgICB0aHJvdyBuZXcgVHlwZUVycm9yKCdJdGVyYXRvci5mcm9tOiBub3QgaXRlcmFibGUnKTsKICAgIH07CiAgfQoKICAvLyAtLS0tIE1hcC5wcm90b3R5cGUuZ2V0T3JJbnNlcnRDb21wdXRlZCDlhZzlupUgKOaWsOaPkOahiCkgLS0tLQogIGlmICghTWFwLnByb3RvdHlwZS5nZXRPckluc2VydCkgewogICAgTWFwLnByb3RvdHlwZS5nZXRPckluc2VydCA9IGZ1bmN0aW9uIChrZXksIHZhbHVlKSB7CiAgICAgIGlmICh0aGlzLmhhcyhrZXkpKSByZXR1cm4gdGhpcy5nZXQoa2V5KTsKICAgICAgdGhpcy5zZXQoa2V5LCB2YWx1ZSk7CiAgICAgIHJldHVybiB2YWx1ZTsKICAgIH07CiAgfQogIGlmICghTWFwLnByb3RvdHlwZS5nZXRPckluc2VydENvbXB1dGVkKSB7CiAgICBNYXAucHJvdG90eXBlLmdldE9ySW5zZXJ0Q29tcHV0ZWQgPSBmdW5jdGlvbiAoa2V5LCBmbikgewogICAgICBpZiAodGhpcy5oYXMoa2V5KSkgcmV0dXJuIHRoaXMuZ2V0KGtleSk7CiAgICAgIHZhciB2ID0gZm4oa2V5KTsKICAgICAgdGhpcy5zZXQoa2V5LCB2KTsKICAgICAgcmV0dXJuIHY7CiAgICB9OwogIH0KCiAgdHJ5IHsKICAgIGdsb2JhbFRoaXMuX19EU0hfUE9MWUZJTExfXyA9ICcxLjAnOwogIH0gY2F0Y2ggKGUpIHt9Cn0pKCk7Cg==
POLY
  say "polyfill.js 已写入（$(wc -c < /www/wwwroot/dsh-polyfill/polyfill.js) 字节）"
else
  warn "polyfill.js 已存在，跳过"
fi

# ── 5. 常见坑：profile 覆盖层放宽 WS 心跳 ──────────────────────────────
say "配置 profile 覆盖层（WebSocket 心跳 30s + 主题跟随系统）"
PROFILE_DIR="$DSH_HOME/profiles/web"
mkdir -p "$PROFILE_DIR"
if [[ ! -f "$PROFILE_DIR/cordis.patch.yml" ]]; then
cat > "$PROFILE_DIR/cordis.patch.yml" <<'PATCH'
# 用户覆盖层（dsh 每次启动都会叠加在 bundle 之上）
# 1) 放宽 WebSocket 心跳：默认 2s + 连丢 2 次 pong 就断，手机浏览器走代理会被误杀
- id: typert-gateway
  config:
    websocketHeartbeatIntervalMs: 30000
# 2) 主题跟随系统
- id: ui-theme
  name: "@deepseek-ai/dsh-client-ui-theme"
  config:
    preference: system
PATCH
else
  warn "cordis.patch.yml 已存在，保留原样（如需心跳放宽请手动加 typert-gateway 段）"
fi

# ── 6. nginx 反代（可选） ─────────────────────────────────────────────
NGINX_BIN="$(command -v nginx || true)"
if [[ -z "$NGINX_BIN" && -n "$PKG" && "${WITH_NGINX:-1}" == "1" ]]; then
  say "安装 nginx"
  if ! pkg_install nginx; then
    warn "nginx 安装失败（上面是真实报错）。常见原因：CentOS 没启用 EPEL、软件源不可用"
    warn "你仍然可以用 SSH 隧道访问：ssh -L $PUBLIC_PORT:127.0.0.1:$DSH_PORT root@$PUBLIC_HOST"
  fi
  NGINX_BIN="$(command -v nginx || true)"
fi
if [[ -n "$NGINX_BIN" ]]; then
  say "配置 nginx 反代 :$PUBLIC_PORT → 127.0.0.1:$DSH_PORT"

  # 宝塔用 /www/server/panel/vhost/nginx，标准发行版用 /etc/nginx/conf.d
  if [[ -d /www/server/panel/vhost/nginx ]]; then
    CONF_DIR=/www/server/panel/vhost/nginx
  elif [[ -d /etc/nginx/conf.d ]]; then
    CONF_DIR=/etc/nginx/conf.d
  else
    CONF_DIR=/etc/nginx
  fi
  CONF_FILE="$CONF_DIR/dsh.conf"

  say "密码文件 /www/wwwroot/dsh.htpasswd"
  mkdir -p /www/wwwroot
  printf '%s:%s\n' "$AUTH_USER" "$(openssl passwd -apr1 "$AUTH_PASS")" > /www/wwwroot/dsh.htpasswd
  { echo "USER=$AUTH_USER"; echo "PASS=$AUTH_PASS"; } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  chmod 640 /www/wwwroot/dsh.htpasswd
  chown root:www /www/wwwroot/dsh.htpasswd 2>/dev/null || true

  if [[ -f "$CONF_FILE" ]]; then
    cp "$CONF_FILE" "$CONF_FILE.bak.$(date +%Y%m%d%H%M%S)"
    warn "已备份原配置：$CONF_FILE.bak.*"
  fi

  cat > "$CONF_FILE" <<NGINX
# DeepSeek Harness (dsh) reverse proxy —— 由 dsh-deploy 生成
server {
    listen $PUBLIC_PORT;
    server_name $PUBLIC_HOST;

    access_log /var/log/nginx/dsh.access.log;
    error_log  /var/log/nginx/dsh.error.log;

    auth_basic "DeepSeek Harness";
    auth_basic_user_file /www/wwwroot/dsh.htpasswd;

    client_max_body_size 100m;

    # 老内核兼容补丁（Chrome 115 缺 AbortSignal.any 等）
    location = /polyfill.js {
        root /www/wwwroot/dsh-polyfill;
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
        # 必须：上游不压缩 HTML，注入才有效
        proxy_set_header Accept-Encoding "";
        sub_filter_once on;
        sub_filter '<head>' '<head><script src="/polyfill.js"></script>';
    }
}
NGINX

  # 关键：nginx 可能刚装好但还没启动过，此时 -s reload 会失败（没有 master 进程）
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    say "启动 nginx"
    systemctl enable --now nginx 2>/dev/null || "$NGINX_BIN" || warn "nginx 启动失败"
    sleep 2
  fi
  if "$NGINX_BIN" -t >/dev/null 2>&1; then
    ("$NGINX_BIN" -s reload || systemctl reload nginx) >/dev/null 2>&1 && say "nginx 已重载" || warn "nginx 重载失败"
  else
    warn "nginx 配置检查失败：$("$NGINX_BIN" -t 2>&1 | tail -3)"
  fi
else
  warn "没装 nginx：dsh 只监听 127.0.0.1:$DSH_PORT，请用 SSH 隧道访问"
  warn "  ssh -L $PUBLIC_PORT:127.0.0.1:$DSH_PORT 你的用户@这台机器"
fi

# ── 7. 防火墙 ──────────────────────────────────────────────────────────
say "放行端口 $PUBLIC_PORT"
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PUBLIC_PORT/tcp" >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
elif command -v ufw >/dev/null 2>&1; then
  ufw allow "$PUBLIC_PORT"/tcp >/dev/null 2>&1 || true
fi

# ── 8. 启动 ────────────────────────────────────────────────────────────
say "启动 dsh"
systemctl daemon-reload
systemctl enable --now dsh
say "等待 dsh 启动（首次要初始化 profile，最多 90 秒）…"
READY=0
for i in $(seq 1 45); do
  if systemctl is-active --quiet dsh && ss -lnt 2>/dev/null | grep -q ":$DSH_PORT"; then READY=1; break; fi
  sleep 2
done
if [[ "$READY" != "1" ]]; then
  warn "dsh 暂时没起来，最近日志："
  tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
  warn "排查：journalctl -u dsh -n 50"
  die "dsh 启动失败（先把上面的日志发我看）"
fi

TOKEN="$(grep -o 'token=[A-Za-z0-9_-]*' "$LOG_FILE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"

cat <<EOF

────────────────────────────────────────────────────────
 ✅ 部署完成

 本机地址   : http://127.0.0.1:$DSH_PORT
 对外地址   : http://$PUBLIC_HOST:$PUBLIC_PORT
 登录账号   : $AUTH_USER
 登录密码   : $AUTH_PASS
 工作区     : $WORKSPACE
 日志       : $LOG_FILE
 服务管理   : systemctl {start|stop|restart|status} dsh

 首次登录（token 换 cookie）：
   $([[ -n "$TOKEN" ]] && echo "http://$PUBLIC_HOST:$PUBLIC_PORT/?token=$TOKEN" || echo "（去日志里找 token：grep -o 'token=[^ ]*' $LOG_FILE | tail -1）")

 下一步：打开页面 → Settings → Models 填 DeepSeek API Key
────────────────────────────────────────────────────────
⚠️ 云服务器安全组也要放行 $PUBLIC_PORT/tcp
EOF
