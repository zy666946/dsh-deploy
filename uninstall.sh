#!/usr/bin/env bash
# ============================================================
# dsh-deploy · 一键卸载
#
#   bash uninstall.sh            # 拆服务和反代，保留聊天数据
#   PURGE=1 bash uninstall.sh    # 连数据一起删（不可恢复）
#   DRY_RUN=1 bash uninstall.sh  # 只打印要做什么，不动手
#
# 保留的数据（不 purge 的话）：
#   $DSH_HOME（会话/配置）  $WORKSPACE（工作区文件）  /var/log/dsh.log
# ============================================================
set -uo pipefail

PURGE="${PURGE:-0}"
DRY_RUN="${DRY_RUN:-0}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"
WORKSPACE="${WORKSPACE:-/www/wwwroot/dsh-workspace}"
POLY_DIR="/www/wwwroot/dsh-polyfill"
TOKEN_FILE="/root/dsh-token.txt"
LOG_FILE="/var/log/dsh.log"
CRED_FILE="/www/wwwroot/dsh.credentials.txt"

say()  { printf '\033[36m▸ %s\033[0m\n' "$*"; }
ok()   { if [ "$DRY_RUN" = "1" ]; then printf '   [dry-run] %s\n' "$*"; else printf '\033[32m✅ %s\033[0m\n' "$*"; fi; }
warn() { printf '\033[33m⚠ %s\033[0m\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] %s\n' "$*"
  else
    eval "$@" >/dev/null 2>&1 || true
  fi
}

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo -i 后再来）"

if [ "$DRY_RUN" != "1" ]; then
  echo
  warn "即将卸载 DeepSeek Harness"
  echo  "   数据目录: $DSH_HOME"
  echo  "   工作区  : $WORKSPACE"
  if [ "$PURGE" = "1" ]; then
    warn "PURGE=1：上面两个目录会被【永久删除】"
  else
    echo  "   这两个目录会保留（要一起删就加 PURGE=1）"
  fi
  printf '\n   继续？[y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

# ── 1. 服务 ─────────────────────────────────────────────────
say "停止并移除 systemd 服务"
run "systemctl stop dsh"
run "systemctl disable dsh"
run "rm -f /etc/systemd/system/dsh.service"
run "rm -rf /etc/systemd/system/dsh.service.d"
run "systemctl daemon-reload"
ok "服务已移除"

# ── 2. nginx 反代 ───────────────────────────────────────────
say "移除 nginx 站点配置"
run "rm -f /etc/nginx/conf.d/dsh.conf"
run "rm -f /etc/nginx/sites-enabled/dsh"
run "rm -f /etc/nginx/sites-available/dsh"
if command -v nginx >/dev/null; then
  if [ "$DRY_RUN" = "1" ]; then
    run "systemctl reload nginx"
  elif nginx -t >/dev/null 2>&1; then
    run "systemctl reload nginx"
    ok "nginx 已重载"
  else
    warn "nginx 配置有问题，跳过重载（执行 nginx -t 看看）"
  fi
fi

# ── 3. polyfill 与密码文件 ──────────────────────────────────
say "移除兼容补丁与临时文件"
run "rm -rf $POLY_DIR"
run "rm -f /www/wwwroot/dsh.htpasswd"
run "rm -f $TOKEN_FILE"
run "rm -f $CRED_FILE"
ok "已清理"

# ── 4. dsh 本体 ─────────────────────────────────────────────
say "卸载 dsh（npm 全局包）"
if command -v npm >/dev/null; then
  run "npm rm -g @deepseek-ai/dsh"
  ok "dsh 已卸载"
else
  warn "没有 npm，跳过"
fi

# ── 5. 数据 ─────────────────────────────────────────────────
if [ "$PURGE" = "1" ]; then
  say "删除数据（不可恢复）"
  run "rm -rf $DSH_HOME"
  run "rm -rf $WORKSPACE"
  run "rm -f $LOG_FILE"
  ok "数据已删除"
else
  warn "数据保留：$DSH_HOME / $WORKSPACE"
  echo  "   要彻底清干净：PURGE=1 bash uninstall.sh"
fi

echo
echo "────────────────────────────────────────────────────────"
if [ "$DRY_RUN" = "1" ]; then
  echo " 🔍 演练完成（什么都没动）"
else
  echo " ✅ 卸载完成"
  [ "$PURGE" != "1" ] && echo "    聊天数据和文件都还在，随时能重装回来。"
fi
echo "   重装：PUBLIC_HOST=你的IP bash install.sh"
echo "────────────────────────────────────────────────────────"
