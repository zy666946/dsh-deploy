# dsh-deploy

> **要重装服务器？** 看 [REINSTALL.md](REINSTALL.md) —— 含备份、部署、恢复、验收的完整步骤。

DeepSeek Harness (dsh) 的一键部署脚本（幂等，可重复执行）。

```bash
bash install.sh
# 或
curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install.sh | bash
```

## 它替你做掉的事

| 步骤 | 说明 |
|---|---|
| 检查 Node | 要求 >= 22，没装会告诉你 |
| 安装 dsh | `npm i -g @deepseek-ai/dsh`（已装则跳过）|
| systemd 服务 | 开机自启 + 崩溃重启 + 日志 `/var/log/dsh.log` |
| polyfill.js | 补 18 项新 API，救 Chrome 116 以下的老内核 |
| nginx 反代 | Basic Auth + WebSocket + polyfill 注入（有 nginx 才做）|
| 心跳放宽 | `websocketHeartbeatIntervalMs: 30000`，救手机浏览器 |
| 防火墙 | firewalld / ufw 自动放行 |

## 可配置项

```bash
PUBLIC_PORT=8080 \
PUBLIC_HOST=1.2.3.4 \
AUTH_USER=dsh \
AUTH_PASS=你的密码 \
WORKSPACE=/data/dsh \
bash install.sh
```

不设 `AUTH_PASS` 会随机生成，并写进 `/www/wwwroot/dsh.credentials.txt`；
**重复执行会复用这份凭据，不会重置密码**。

## 两个已知坑（脚本已处理）

1. **手机浏览器一直“重连中”**：dsh 默认 2s 一次 WS ping，连丢两次 pong 就断；
   移动网络代理会吞控制帧 → 脚本把间隔改成 30s。
2. **Chrome 115 及以下白屏**：前端用了 `AbortSignal.any`（Chrome 116+）→
   注入 polyfill 补齐 18 项 API。

## 注意

- 脚本会覆盖 nginx 的 `dsh.conf`（原文件会备份成 `.bak.时间戳`）
- 只监听 `127.0.0.1`，对外一律走 nginx + Basic Auth
- 云服务器安全组仍需手动放行 `PUBLIC_PORT/tcp`


---

# install-qq.sh —— 把 QQ 接进来

```bash
QQ_NUMBER=机器人号 OWNER_QQ=你的号 bash install-qq.sh
```

| 步骤 | 内容 |
|---|---|
| NapCat | 自动装 NapCat + 官方 QQ（约 200MB）|
| OneBot | 写好 v11 WS 配置，只绑 `127.0.0.1:3001`，带随机 token |
| systemd | `napcat.service` 开机自启 + 内存上限 |
| profile | 建专用 `qq` profile（QQ 聊天的常驻 SDK 会话）|
| 插件 | clone [dsh-qq](https://github.com/zy666946/dsh-qq) 并挂进 web profile |
| 配置 | 自动写白名单、OneBot 地址、thinkPort |

**只剩扫码一步**：脚本启动后打印二维码路径，手机 QQ 扫一下即可。

之后：

```bash
ss -lnt | grep 3001                 # 确认 OneBot 起来了
systemctl restart dsh               # 让插件加载
curl -s http://127.0.0.1:3002/api/qq/state   # 应返回 connected:true
```

## 顺序很重要

**先跑 `install.sh`（装 dsh），再跑 `install-qq.sh`（接 QQ）**。反过来会找不到 dsh。

## 两个插件（可选）

```bash
# 人格（内置干饭鱼）
git clone https://github.com/zy666946/dsh-agent-md \
  "${DSH_HOME:-$HOME/.dsh}/plugins/dsh-agent-md"

# 主动心跳
git clone https://github.com/zy666946/dsh-heartbeat-inner \
  "${DSH_HOME:-$HOME/.dsh}/plugins/dsh-heartbeat-inner"
```

挂载方式和 dsh-qq 一样：`node_modules` 做软链 + `package.json` 的 `bundles` 加一行。
