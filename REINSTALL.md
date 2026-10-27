# 服务器重装 · 完整步骤

> 从「现在的机器」到「新机器跑起来」，一步步来，别跳。

---

## 阶段 0：重装前，先把东西捞出来（**最重要**）

格式化之后服务器上什么都不剩，所以先备份：

```bash
curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/backup.sh | bash
```

会在 `/root/dsh-backup-时间戳/` 生成：

| 文件 | 内容 |
|---|---|
| `dsh-home.tar.gz` | 人格、profile 配置、聊天记录、插件、**API Key** |
| `web-config.tar.gz` | 网页密码、polyfill、systemd 单元、nginx 配置 |
| `README.md` | 清单 + 还原命令 |
| `workspace.tar.gz` | 你的项目文件（需要 `WITH_WORKSPACE=1`）|

**然后立刻下载到本地**（留在服务器上等于没备份）：

```bash
scp -r root@你的服务器:/root/dsh-backup-* ./
```

顺手记下这些（重装后要用）：

- [ ] 机器人 QQ 号 + 扫码用的手机
- [ ] 你的 QQ 号（白名单）
- [ ] DeepSeek API Key（在 `dsh-home.tar.gz` 的 `.dsh/.credentials.yaml` 里，但建议单独记一份）
- [ ] 网页登录密码（在 `web-config.tar.gz` 里）
- [ ] 云服务器**安全组**要放行的端口号

---

## 阶段 1：重装系统

在云厂商控制台重装，建议：

| 项 | 建议 |
|---|---|
| 镜像 | Ubuntu 22.04 / 24.04，或 Debian 12（apt 生态最省事）|
| 内存 | ≥ 2G（脚本会自动开 swap）|
| 磁盘 | ≥ 20G（NapCat + QQ 要 1G+）|

---

## 阶段 2：基础安全（可选但建议）

```bash
# 改 root 密码
passwd

# 更新系统
apt update && apt upgrade -y     # Debian/Ubuntu
# 或 dnf update -y                # CentOS/RHEL

# 云厂商安全组：放行 SSH(22) 和网页端口(默认 3081)
```

---

## 阶段 3：三条命令

```bash
# ① 基础设施（自动装 Node / nginx / 基础工具 / swap / 时区）
curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install.sh | bash

# ② QQ 接入（NapCat + OneBot + 插件）
QQ_NUMBER=机器人号 OWNER_QQ=你的号 \
  bash <(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-qq.sh)

# ③ 插件（人格 + 心跳）
bash <(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-plugins.sh)
```

### 每步之后的人工动作

**① 之后**
- 打开脚本打印的地址（`http://IP:3081`）
- 账号密码也在输出里
- 用带 token 的链接换 cookie
- Settings → Models 填 DeepSeek API Key

**② 之后**
- 扫码：`/www/wwwroot/napcat/napcat/cache/qrcode.png`
- 确认：`ss -lnt | grep 3001`
- 重启：`systemctl restart dsh`

**③ 之后**
- 重启：`systemctl restart dsh`
- 设置里检查「人格」「心跳」两个页面

---

## 阶段 4：恢复数据（可选）

如果想把旧的人格 / 聊天记录 / 密码原样搬回来：

```bash
tar xzf dsh-home.tar.gz -C /
tar xzf web-config.tar.gz -C /
systemctl daemon-reload
systemctl restart dsh
nginx -t && nginx -s reload
```

⚠️ 顺序：**先在阶段 3 把环境装好，再恢复数据**。反了会因为文件不存在报错。
⚠️ 恢复 `dsh-home.tar.gz` 会覆盖新机器上刚生成的配置（包括 `cordis.patch.yml`），
   如果你在新机器上改过插件配置，先备份再恢复。

---

## 阶段 5：验收清单

跑一遍这个，全绿才算成功：

```bash
echo "--- 服务 ---"
systemctl is-active dsh napcat

echo "--- 端口 ---"
ss -lnt | grep -E ':3080|:3081|:3001|:3002'

echo "--- dsh 版本 ---"
dsh --version

echo "--- QQ 插件 ---"
curl -s http://127.0.0.1:3002/api/qq/state | head -c 200

echo "--- 心跳 ---"
curl -s -u dsh:你的密码 http://127.0.0.1:3081/api/heartbeat/state | head -c 200

echo "--- 网页 ---"
curl -s -o /dev/null -w '%{http_code}\n' -u dsh:你的密码 http://127.0.0.1:3081/

echo "--- polyfill ---"
curl -s -o /dev/null -w '%{http_code}\n' -u dsh:你的密码 http://127.0.0.1:3081/polyfill.js
```

期望：`active active`、四个端口都在、`200 200`、两个 JSON 有内容。

### 最后两个真机测试

1. **QQ**：用你的号给机器人发一句话，应该几秒内回复
2. **心跳**：`设置 → 心跳 → 现在就想一次`，看它是否发消息 / 或说明为什么不发

---

## 常见问题

| 现象 | 原因 |
|---|---|
| `install.sh` 卡在 Node 下载 | 网络问题，可先手动装 Node 22 再跑 |
| 网页打不开 | 安全组没放行端口 / nginx 没起 |
| 登录后一直"重连中" | 手机浏览器太老（polyfill 已处理），换 Chrome |
| QQ 连不上 | NapCat 没启动 / token 不一致 / 端口不是 3001 |
| 设置页 404 | 插件没挂到 webServer（用 0.1.1+ 版本）|
| 心跳一直不发 | 安静时段（0-7 点）或今天发够了；手动触发试试 |

---

## 一句话版

```bash
# 旧机器
curl -fsSL .../backup.sh | bash && scp -r root@旧机:/root/dsh-backup-* ./

# 新机器
curl -fsSL .../install.sh | bash
QQ_NUMBER=xxx OWNER_QQ=yyy bash <(curl -fsSL .../install-qq.sh)
bash <(curl -fsSL .../install-plugins.sh)
# 然后：扫码 → 填 API Key → 重启 → 验收
```
