#!/usr/bin/env bash
#
# install-qq —— 把 QQ 接进 DeepSeek Harness（除扫码外全自动）
#
#   QQ_NUMBER=3214926616 OWNER_QQ=319085634 bash install-qq.sh
#
# 做这些事：
#   1. 装 NapCat（Linux 一键安装器 + 官方 QQ）
#   2. 写 OneBot v11 正向 WebSocket 配置（只绑 127.0.0.1）
#   3. 配 NapCat 的 systemd 服务（开机自启、内存上限）
#   4. 建专用 profile `qq`（QQ 聊天用的常驻 SDK 会话）
#   5. 装 dsh-qq 插件并挂进 web profile
#   6. 写 web profile 的插件配置
#   7. 启动 NapCat，打印二维码路径
#
set -euo pipefail

QQ_NUMBER="${QQ_NUMBER:-}"
OWNER_QQ="${OWNER_QQ:-}"
ONEBOT_PORT="${ONEBOT_PORT:-3001}"
ONEBOT_TOKEN="${ONEBOT_TOKEN:-$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)}"
NAPCAT_DIR="${NAPCAT_DIR:-/www/wwwroot/napcat}"
WORKSPACE="${WORKSPACE:-/www/wwwroot/dsh-workspace}"
DSH_HOME="${DSH_HOME:-/root/.dsh}"
PLUGIN_SRC="${PLUGIN_SRC:-https://github.com/zy666946/dsh-qq}"
CRED_FILE="${CRED_FILE:-/www/wwwroot/dsh.qq.credentials.txt}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -n "$QQ_NUMBER" ]] || die "缺少 QQ_NUMBER（机器人 QQ 号），例如：QQ_NUMBER=123456 bash install-qq.sh"
[[ -n "$OWNER_QQ" ]] || die "缺少 OWNER_QQ（你的 QQ 号，白名单），例如：OWNER_QQ=10001 bash install-qq.sh"
command -v dsh >/dev/null 2>&1 || die "找不到 dsh，请先跑 install.sh"

# 复用上次的 token，避免重复执行把已连好的客户端踢掉
if [[ -f "$CRED_FILE" ]]; then
  ONEBOT_TOKEN="$(sed -n 's/^TOKEN=//p' "$CRED_FILE" | head -1 || true)"
  [[ -n "$ONEBOT_TOKEN" ]] || ONEBOT_TOKEN="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
fi

# ── 1. NapCat ──────────────────────────────────────────────────────────
mkdir -p "$NAPCAT_DIR"
cd "$NAPCAT_DIR"

if [[ -x "$NAPCAT_DIR/launcher.sh" ]] && [[ -f "/opt/QQ/resources/app/package.json" ]]; then
  say "NapCat 与 QQ 已安装，跳过"
else
  say "安装 NapCat + 官方 QQ（约 200MB 下载，耐心等）"
  curl -fL -o napcat-linux.sh https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/main/install.sh
  bash napcat-linux.sh --github-proxy 0
fi

# ── 2. OneBot v11 配置 ────────────────────────────────────────────────
say "写 OneBot 配置（127.0.0.1:$ONEBOT_PORT）"
mkdir -p "$NAPCAT_DIR/napcat/config"
cat > "$NAPCAT_DIR/napcat/config/onebot11_${QQ_NUMBER}.json" <<JSON
{
  "network": {
    "httpServers": [],
    "httpSseServers": [],
    "httpClients": [],
    "websocketServers": [
      {
        "name": "dsh-qq",
        "enable": true,
        "host": "127.0.0.1",
        "port": $ONEBOT_PORT,
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "token": "$ONEBOT_TOKEN",
        "debug": false,
        "heartInterval": 30000
      }
    ],
    "websocketClients": [],
    "plugins": []
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
JSON

# ── 3. NapCat systemd ─────────────────────────────────────────────────
say "写 napcat.service（开机自启）"
cat > /etc/systemd/system/napcat.service <<SERVICE
[Unit]
Description=NapCat QQ sidecar (OneBot v11)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$NAPCAT_DIR
Environment=HOME=/root
ExecStart=/bin/bash $NAPCAT_DIR/launcher.sh -q $QQ_NUMBER
Restart=always
RestartSec=20
MemoryHigh=1400M
MemoryMax=1800M
StandardOutput=append:/var/log/napcat.log
StandardError=append:/var/log/napcat.log
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload

# ── 4. 专用 profile ───────────────────────────────────────────────────
if [[ -d "$DSH_HOME/profiles/qq" ]]; then
  say "profile qq 已存在，跳过创建"
else
  say "创建 profile qq（基于 sdk 模板）"
  ( cd "$WORKSPACE" 2>/dev/null || cd /tmp
    dsh --profile qq --from-default-profile sdk --dump-config >/dev/null 2>&1 ) || warn "profile 初始化返回非零（可能只是 dump 的退出码），继续"
fi

# ── 5. 插件 ───────────────────────────────────────────────────────────
PLUGIN_DIR="$DSH_HOME/plugins/dsh-qq"
if [[ -d "$PLUGIN_DIR/.git" ]]; then
  say "更新 dsh-qq 插件"
  git -C "$PLUGIN_DIR" pull --ff-only || warn "插件更新失败（可能是本地改动），继续用现有版本"
else
  say "安装 dsh-qq 插件"
  mkdir -p "$DSH_HOME/plugins"
  git clone --depth 1 "$PLUGIN_SRC" "$PLUGIN_DIR"
fi

WEB_PROFILE="$DSH_HOME/profiles/web"
mkdir -p "$WEB_PROFILE/node_modules"
ln -sfn "$PLUGIN_DIR" "$WEB_PROFILE/node_modules/dsh-qq"

say "把插件挂进 web profile"
node -e '
const fs = require("fs");
const p = process.argv[1];
const plugin = process.argv[2];
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.dependencies = j.dependencies || {};
j.dependencies["dsh-qq"] = "link:../../plugins/dsh-qq";
j.dsh = j.dsh || {};
j.dsh.profile = j.dsh.profile || {};
j.dsh.profile.bundles = j.dsh.profile.bundles || [];
if (!j.dsh.profile.bundles.includes("dsh-qq")) j.dsh.profile.bundles.push("dsh-qq");
fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n");
console.log("bundles:", j.dsh.profile.bundles.join(", "));
' "$WEB_PROFILE/package.json"

# ── 6. 插件配置 ───────────────────────────────────────────────────────
PATCH="$WEB_PROFILE/cordis.patch.yml"
if grep -q '^- id: qq$\|^  - id: qq$' "$PATCH" 2>/dev/null; then
  say "cordis.patch.yml 已有 qq 配置，跳过"
else
  say "追加 qq 配置到 cordis.patch.yml"
  cat >> "$PATCH" <<YAML

# ── dsh-qq：QQ 接入 ──
- id: qq
  config:
    enabled: true
    onebotUrl: "ws://127.0.0.1:$ONEBOT_PORT?access_token=$ONEBOT_TOKEN"
    selfId: "$QQ_NUMBER"
    allowUsers: ["$OWNER_QQ"]
    allowGroups: []
    groupAtOnly: true
    politeReject: true
    profile: qq
    dshBin: "$(command -v dsh)"
    cwd: "$WORKSPACE"
    thinkPort: 3002
YAML
fi

printf 'TOKEN=%s\nOWNER=%s\nBOT=%s\n' "$ONEBOT_TOKEN" "$OWNER_QQ" "$QQ_NUMBER" > "$CRED_FILE"
chmod 600 "$CRED_FILE"

# ── 7. 启动 NapCat 并出二维码 ─────────────────────────────────────────
say "启动 NapCat（首次需要扫码登录）"
systemctl enable --now napcat
say "等待二维码（最多 60 秒）…"
for i in $(seq 1 60); do
  if [[ -f "$NAPCAT_DIR/napcat/cache/qrcode.png" ]]; then break; fi
  sleep 1
done

echo
if [[ -f "$NAPCAT_DIR/napcat/cache/qrcode.png" ]]; then
  printf '\033[1;36m扫码登录：%s\033[0m\n' "$NAPCAT_DIR/napcat/cache/qrcode.png"
  grep -a "二维码解码URL" /var/log/napcat.log 2>/dev/null | tail -1 || true
else
  warn "还没出二维码，看看日志：tail -50 /var/log/napcat.log"
fi

cat <<EOF

────────────────────────────────────────────────────────
 ✅ NapCat 已启动，QQ 插件已挂好

 下一步（顺序别乱）：
   1. 扫码：把 $NAPCAT_DIR/napcat/cache/qrcode.png 发给手机扫
      （或用上面那条「二维码解码URL」自己生成）
   2. 确认登录成功：ss -lnt | grep $ONEBOT_PORT   # 看到监听就对了
   3. 重启 dsh 让插件加载：systemctl restart dsh
   4. 验证：curl -s http://127.0.0.1:3002/api/qq/state
   5. 打开网页设置 → QQ，刷新应显示「已连接」

 凭据已存：$CRED_FILE（OneBot token / 白名单号）
 日志：/var/log/napcat.log、/var/log/dsh.log
────────────────────────────────────────────────────────
EOF
