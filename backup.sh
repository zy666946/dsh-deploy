#!/usr/bin/env bash
#
# backup —— 重装系统前，把 dsh 相关的一切打包出来
#
#   bash backup.sh                 # 输出到 /root/dsh-backup-时间戳/
#   OUT=/data bash backup.sh
#
set -euo pipefail

OUT="${OUT:-/root}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/dsh-backup-$STAMP"
DSH_HOME="${DSH_HOME:-/root/.dsh}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
mkdir -p "$DEST"

say "备份到 $DEST"

# ── 1. dsh 的配置与数据 ────────────────────────────────────────────────
say "打包 $DSH_HOME（人格 / 配置 / 会话 / 插件 / 凭据）"
tar czf "$DEST/dsh-home.tar.gz" \
  -C / \
  --exclude='*.lock' \
  --exclude='node_modules' \
  ${DSH_HOME#/} 2>/dev/null || warn "$DSH_HOME 打包有警告（可能部分文件被占用），继续"

# ── 2. 网页侧的凭据与补丁 ──────────────────────────────────────────────
say "打包网页凭据 / polyfill / nginx 配置"
tar czf "$DEST/web-config.tar.gz" -C / \
  www/wwwroot/dsh.credentials.txt \
  www/wwwroot/dsh.qq.credentials.txt \
  www/wwwroot/dsh.htpasswd \
  www/wwwroot/dsh-polyfill \
  etc/systemd/system/dsh.service \
  etc/systemd/system/napcat.service \
  etc/systemd/system/qq-bridge.service \
  www/server/panel/vhost/nginx/dsh.conf \
  2>/dev/null || warn "部分文件不存在（正常，取决于你装了什么）"

# ── 3. 工作区文件（可选，可能很大）────────────────────────────────────
if [[ "${WITH_WORKSPACE:-0}" == "1" ]]; then
  say "打包工作区 ${WORKSPACE:-/www/wwwroot/龙虾/dsh-workspace}"
  tar czf "$DEST/workspace.tar.gz" -C / "${WORKSPACE#/}" 2>/dev/null || warn "工作区打包失败"
else
  warn "跳过工作区（加 WITH_WORKSPACE=1 可一并打包）"
fi

# ── 4. 清单 ────────────────────────────────────────────────────────────
say "生成还原清单"
{
  echo "# dsh 备份清单 — $STAMP"
  echo
  echo "## 系统"
  echo "- 主机名: $(hostname)"
  echo "- 系统: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  echo "- 内存: $(free -h | awk '/Mem:/{print $2}')"
  echo "- 时区: $(timedatectl 2>/dev/null | awk -F': ' '/Time zone/{print $2}')"
  echo
  echo "## 关键信息（重装后要重新填）"
  echo "- dsh 版本: $(dsh --version 2>/dev/null || echo 未知)"
  echo "- 工作区: ${WORKSPACE:-未知}"
  echo
  echo "## 文件"
  echo "- dsh-home.tar.gz   : 人格 / profile 配置 / 会话 / 插件 / API Key"
  echo "- web-config.tar.gz : 密码文件 / polyfill / systemd / nginx"
  [[ "${WITH_WORKSPACE:-0}" == "1" ]] && echo "- workspace.tar.gz  : 工作区文件"
  echo
  echo "## 还原步骤"
  echo '```bash'
  echo 'tar xzf dsh-home.tar.gz -C /'
  echo 'tar xzf web-config.tar.gz -C /'
  echo 'systemctl daemon-reload'
  echo 'systemctl restart dsh'
  echo '```'
} > "$DEST/README.md"

echo
printf '\033[1;36m完成：%s\033[0m\n' "$DEST"
ls -lh "$DEST"
echo
echo "把整个目录下载到本地（别留在服务器上，格式化就没了）："
echo "  scp -r root@这台机器:$DEST ./"
