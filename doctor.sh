#!/usr/bin/env bash
#
# doctor —— dsh 部署自检 / 故障诊断
#
#   bash doctor.sh
#   bash doctor.sh http://1.2.3.4:3081     # 指定要测的地址
#
# 只读，不改任何配置。把输出整段发出去就能定位问题。
set -uo pipefail

TARGET="${1:-}"
DSH_PORT="${DSH_PORT:-3080}"
PUBLIC_PORT="${PUBLIC_PORT:-3081}"
PASS_FILE="/www/wwwroot/dsh.credentials.txt"
LOG_D=""
ok()   { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✘\033[0m %s\n' "$*"; }
info() { printf '  \033[1;36m·\033[0m %s\n' "$*"; }
h()    { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

CRED_USER="dsh"; CRED_PASS=""
if [[ -f "$PASS_FILE" ]]; then
  CRED_USER="$(sed -n 's/^USER=//p' "$PASS_FILE" | head -1)"; CRED_USER="${CRED_USER:-dsh}"
  CRED_PASS="$(sed -n 's/^PASS=//p' "$PASS_FILE" | head -1)"
fi
AUTH=()
[[ -n "$CRED_PASS" ]] && AUTH=(-u "$CRED_USER:$CRED_PASS")

h "系统"
info "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")  |  内核 $(uname -r)"
info "内存 $(free -h | awk '/Mem:/{print $2}')  可用 $(free -h | awk '/Mem:/{print $7}')  |  swap $(free -h | awk '/Swap:/{print $2}')"
info "Node $(node -v 2>/dev/null || echo '未安装')  |  dsh $(dsh --version 2>/dev/null || echo '不在 PATH')"

h "服务"
for s in dsh nginx; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then ok "$s 运行中"; else bad "$s 未运行（systemctl status $s）"; fi
done

h "端口"
if ss -lnt 2>/dev/null | grep -q ":$DSH_PORT"; then ok "dsh 监听 $DSH_PORT"; else bad "dsh 没监听 $DSH_PORT"; fi
if ss -lnt 2>/dev/null | grep -q ":$PUBLIC_PORT"; then ok "nginx 监听 $PUBLIC_PORT"; else bad "nginx 没监听 $PUBLIC_PORT"; fi

h "直连 dsh（绕开 nginx）"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$DSH_PORT/" 2>/dev/null)
case "$code" in
  401|200|303) ok "dsh 本机响应 $code（正常，401 是它自己的登录门）" ;;
  000) bad "连不上 127.0.0.1:$DSH_PORT" ;;
  *) bad "dsh 返回 $code" ;;
esac

h "经 nginx 访问"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$PUBLIC_PORT/" 2>/dev/null)
case "$code" in
  401) ok "无密码 → 401（密码保护生效）" ;;
  000) bad "连不上 127.0.0.1:$PUBLIC_PORT" ;;
  *)   bad "无密码 → $code（预期 401）" ;;
esac

if [[ ${#AUTH[@]} -gt 0 ]]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${AUTH[@]}" "http://127.0.0.1:$PUBLIC_PORT/polyfill.js" 2>/dev/null)
  [[ "$code" == "200" ]] && ok "带密码取 polyfill.js → 200" || bad "带密码取 polyfill.js → $code"

  TOKEN="$(grep -o 'token=[A-Za-z0-9_-]*' /var/log/dsh.log 2>/dev/null | tail -1 | cut -d= -f2)"
  if [[ -n "$TOKEN" ]]; then
    JAR=$(mktemp)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${AUTH[@]}" -c "$JAR" "http://127.0.0.1:$PUBLIC_PORT/?token=$TOKEN" 2>/dev/null)
    [[ "$code" == "200" || "$code" == "303" ]] && ok "token 换 cookie → $code" || bad "token 换 cookie → $code"
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${AUTH[@]}" -b "$JAR" "http://127.0.0.1:$PUBLIC_PORT/" 2>/dev/null)
    [[ "$code" == "200" ]] && ok "带 cookie 打开首页 → 200" || bad "带 cookie 打开首页 → $code"
    rm -f "$JAR"
  else
    bad "日志里找不到 token"
  fi
else
  info "没有 $PASS_FILE，跳过带密码测试"
fi

if [[ -n "$TARGET" ]]; then
  h "从公网形态访问（$TARGET）"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$TARGET" 2>/dev/null)
  info "直接访问 → $code（401 正常；5xx 说明 nginx→dsh 这段有问题）"
fi

h "nginx 错误日志（最近 10 行）"
ERRLOG=""
for f in /var/log/nginx/dsh.error.log /var/log/nginx/error.log /www/wwwlogs/dsh.error.log; do
  [[ -f "$f" ]] && ERRLOG="$f" && break
done
if [[ -n "$ERRLOG" ]]; then
  if grep -qiE "error|crit|denied" "$ERRLOG" 2>/dev/null; then
    grep -iE "error|crit|denied" "$ERRLOG" 2>/dev/null | tail -10 | sed 's/^/    /'
  else
    ok "没有错误（$ERRLOG）"
  fi
else
  info "找不到 nginx 错误日志"
fi

h "dsh 日志（最近 15 行）"
if [[ -f /var/log/dsh.log ]]; then
  tail -15 /var/log/dsh.log 2>/dev/null | sed 's/^/    /'
else
  info "没有 /var/log/dsh.log"
fi

h "dsh 的 systemd 最近日志"
journalctl -u dsh -n 10 --no-pager 2>/dev/null | sed 's/^/    /' || info "无 journal"

h "结论提示"
info "首页 401 是正常的（dsh 自己要 token）；带 cookie 仍 5xx 才是故障"
info "5xx 常见原因：dsh 没起来 / 首次初始化未完成 / 密码文件 nginx 读不到 / Host 校验"
