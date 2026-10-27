#!/usr/bin/env bash
#
# install-plugins —— 安装并挂载 dsh 的三个配套插件
#
#   bash install-plugins.sh            # 装人格 + 心跳（推荐）
#   WITH_QQ=1 bash install-plugins.sh  # 连 QQ 插件一起（等同 install-qq.sh 的插件部分）
#
# 幂等：已 clone 的会 git pull，已挂载的不会重复添加。
set -euo pipefail

DSH_HOME="${DSH_HOME:-/root/.dsh}"
WEB_PROFILE="$DSH_HOME/profiles/web"
PLUGINS_DIR="$DSH_HOME/plugins"
WITH_QQ="${WITH_QQ:-0}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"
command -v node >/dev/null 2>&1 || die "找不到 node"
mkdir -p "$PLUGINS_DIR" "$WEB_PROFILE/node_modules"

install_plugin() {
  local name="$1" repo="$2"
  local dir="$PLUGINS_DIR/$name"

  if [[ -d "$dir/.git" ]]; then
    say "更新 $name"
    git -C "$dir" pull --ff-only >/dev/null 2>&1 || warn "$name 更新失败，用现有版本"
  else
    say "安装 $name"
    git clone --depth 1 "$repo" "$dir" || { warn "$name clone 失败，跳过"; return 1; }
  fi

  ln -sfn "$dir" "$WEB_PROFILE/node_modules/$name"
  say "$name 已挂载 → $WEB_PROFILE/node_modules/$name"
}

# 人格插件（内置干饭鱼人格，空人格时自动启用）
install_plugin dsh-agent-md https://github.com/zy666946/dsh-agent-md || true

# 心跳插件
install_plugin dsh-heartbeat-inner https://github.com/zy666946/dsh-heartbeat-inner || true

# QQ 插件（可选）
if [[ "$WITH_QQ" == "1" ]]; then
  install_plugin dsh-qq https://github.com/zy666946/dsh-qq || true
fi

# ── 改 web profile 的 package.json ────────────────────────────────────
say "登记到 web profile 的 bundles"
PLUGIN_NAMES=(dsh-agent-md dsh-heartbeat-inner)
if [[ "$WITH_QQ" == "1" ]]; then PLUGIN_NAMES+=(dsh-qq); fi

node -e '
const fs = require("fs");
const [file, ...names] = process.argv.slice(1);
const j = JSON.parse(fs.readFileSync(file, "utf8"));
j.dependencies = j.dependencies || {};
j.dsh = j.dsh || {};
j.dsh.profile = j.dsh.profile || {};
j.dsh.profile.bundles = j.dsh.profile.bundles || [];
for (const name of names) {
  j.dependencies[name] = "link:../../plugins/" + name;
  if (!j.dsh.profile.bundles.includes(name)) j.dsh.profile.bundles.push(name);
}
fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
console.log("bundles:", j.dsh.profile.bundles.join(", "));
' "$WEB_PROFILE/package.json" "${PLUGIN_NAMES[@]}"

# ── 心跳配置 ─────────────────────────────────────────────────────────
PATCH="$WEB_PROFILE/cordis.patch.yml"
if [[ -d "$PLUGINS_DIR/dsh-heartbeat-inner" ]] && ! grep -q "id: heartbeat" "$PATCH" 2>/dev/null; then
  say "追加 heartbeat 配置"
  THINK_PORT=3002
  # 装了 QQ 插件就用它的 profile（共用常驻会话），否则退回 sdk
  if [[ -d "$DSH_HOME/profiles/qq" ]]; then HB_PROFILE=qq; else HB_PROFILE=sdk; fi
  say "心跳将使用 profile: $HB_PROFILE"
  # 如果跑过 install-qq.sh，就把 OneBot 地址和你自己的号自动填进来
  QQ_CRED="${QQ_CRED:-/www/wwwroot/dsh.qq.credentials.txt}"
  HB_WS=""
  HB_TARGET=""
  if [[ -f "$QQ_CRED" ]]; then
    QQ_TOKEN="$(sed -n 's/^TOKEN=//p' "$QQ_CRED" | head -1)"
    QQ_OWNER="$(sed -n 's/^OWNER=//p' "$QQ_CRED" | head -1)"
    ONEBOT_PORT="${ONEBOT_PORT:-3001}"
    if [[ -n "$QQ_TOKEN" ]]; then HB_WS="ws://127.0.0.1:$ONEBOT_PORT?access_token=$QQ_TOKEN"; fi
    HB_TARGET="$QQ_OWNER"
    say "已从 $QQ_CRED 读到 OneBot 配置（目标 QQ: ${HB_TARGET:-未设置}）"
  fi

  cat >> "$PATCH" <<YAML

# ── dsh-heartbeat-inner：主动心跳 ──
- id: heartbeat
  config:
    enabled: true
    intervalMinutes: 30
    startDelaySeconds: 150
    quietFrom: 0
    quietTo: 7
    minGapMinutes: 120
    userActiveMinutes: 40
    dailyMax: 5
    cwd: "${WORKSPACE:-/root}"
    dshBin: "$(command -v dsh)"
    profile: ${HB_PROFILE}
    thinkUrl: "http://127.0.0.1:$THINK_PORT"
    channel:
      kind: onebot
      wsUrl: "$HB_WS"
      targetId: "$HB_TARGET"
YAML
fi

cat <<EOF

────────────────────────────────────────────────────────
 ✅ 插件就绪

 已挂载：
   - dsh-agent-md         人格（空人格时自动启用「干饭鱼」）
   - dsh-heartbeat-inner  主动心跳
 $( [[ "$WITH_QQ" == "1" ]] && echo "  - dsh-qq               QQ 接入" )

 下一步：
   1. systemctl restart dsh
   2. 打开网页 → 设置 → 人格 / 心跳（QQ）
   3. 心跳的「发给哪个 QQ」需要填你的号（或在设置页里改）
────────────────────────────────────────────────────────
EOF
