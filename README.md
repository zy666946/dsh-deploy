# dsh-deploy

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（简称 dsh）装到你自己的 Linux 服务器上：
Node 环境、dsh、开机自启、nginx 反向代理、老浏览器兼容补丁，一条命令搞定。

装完就是一个浏览器打开就能用的网页版 DSH，手机也能进。接 QQ 的话看 [install-qq.sh](install-qq.sh)。

---

## 两个版本，选一个

| | `install.sh`（完整版，424 行） | `install-lite.sh`（精简版，280 行） |
|---|---|---|
| Node | 官方二进制，固定 24.x | NodeSource 源，24 失败回退 22 |
| 依赖 | 全（git/openssl/xz/tar，EPEL 处理） | 少（只装必要） |
| 自检 | dsh smoke test + 部署后自检 | 启动后看日志 |
| Basic Auth | 默认开 | 默认关（`WITH_AUTH=1` 打开） |
| 防火墙 | 自动放行 | 提示 + ufw/firewalld 自动放行 |
| polyfill | ✅ | ✅ |
| 适合 | 干净新机器、想一次到位 | 已经有环境、想少改系统 |

两个脚本**互不依赖**，都不会删对方的东西。

### 完整版

```bash
PUBLIC_HOST=1.2.3.4 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install.sh)"
```

### 精简版

```bash
PUBLIC_HOST=1.2.3.4 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-lite.sh)"
```

> 脚本**不需要** API Key。装完打开网页，在「设置 → 模型 → API 密钥」里填就行，
> 比写在命令行里干净（不会进 shell 历史、不会出现在 `ps` 里）。

---

## 参数

| 变量 | install.sh | install-lite.sh | 说明 |
|------|-----------|-----------------|------|
| `PUBLIC_HOST` | ✅ | ✅ | 公网 IP；精简版不传会尝试自动探测 |
| `PUBLIC_PORT` | ✅ 3081 | ✅ 3081 | 对外端口 |
| `DSH_PORT` | ✅ 3080 | ✅ 3080 | 内部端口，只监听 127.0.0.1 |
| `AUTH_USER` / `AUTH_PASS` | ✅ dsh / 随机 | — | Basic Auth 账号密码 |
| `WITH_AUTH` | — | 默认 0 | 精简版里设为 1 才开 Basic Auth |
| `DEEPSEEK_API_KEY` | — | 可选 | 模型密钥；**建议留空**，装完在网页里填 |
| `WORKSPACE` | `/www/wwwroot/dsh-workspace` | 同左 | 工作区 |
| `NODE_MAJOR` | 24 | 24（回退 22） | Node 大版本 |

---

## 装完怎么用

脚本最后会打印一条**带 token 的链接**：

```
http://1.2.3.4:3081/?token=xxxxxxxx
```

1. 先点它（token 换 cookie，30 天有效）
2. 之后收藏 `http://1.2.3.4:3081/` 就行

### 配置模型 API Key（装完之后）

脚本不碰密钥，装完自己填：

1. 打开 `http://你的IP:3081/`
2. 左下角 **设置 → 模型**
3. 找到 **API 密钥**，粘贴你的 `sk-...`，保存
4. 状态会从「API 密钥缺失」变成「API 密钥已配置」

保存后落在 `$DSH_HOME/.credentials.yaml`（权限 600），重启不丢。

> 为什么不在命令行传 key：会留在 shell 历史里，`ps` 也能看到，多一个泄露面。

### token 每次重启都会变

dsh 的 token 是**启动时随机生成**的。最新的永远在这两处：

```bash
cat /root/dsh-token.txt
grep -o 'token=[A-Za-z0-9_-]*' /var/log/dsh.log | tail -1
```

### 端口打不开

1. **云厂商控制台 → 安全组 → 放行端口**（这步脚本改不了，必须自己去点）
2. 本机防火墙：`ufw allow 3081/tcp`
3. 本机自测：`curl -I http://127.0.0.1:3081`

---

## 踩坑记录（都是真机踩出来的）

### 1. 手机浏览器一直「重新连接中」

dsh 前端用了 Chrome **116+** 的 API：`AbortSignal.any`、`Promise.withResolvers`、`URL.parse`、
`Object.groupBy`、`Set` 新方法、`Symbol.dispose`、`Iterator.from`……
手机厂商自带浏览器多是 115 内核，缺这些会**白屏或无限重连**。

解法：往 `<head>` 注入 polyfill。两个细节少一个都不生效：

```nginx
proxy_set_header Accept-Encoding "";   # 上游压缩了 HTML，sub_filter 匹配不到
sub_filter_once on;
sub_filter '<head>' '<head><script src="/polyfill.js"></script>';
```

> 另一档保险是放宽 WS 心跳（默认 2 秒、连丢两次 pong 就断，弱网很容易被误杀）：
>
> ```yaml
> # $DSH_HOME/profiles/web/cordis.patch.yml
> - id: typert-gateway
>   config:
>     websocketHeartbeatIntervalMs: 30000
> ```
>
> 实测结论：**polyfill 是病根，心跳是保险**。只上 polyfill 就能修好旧内核的重连。

### 2. API 全 403 / 白屏

nginx 的 `Host` 头必须带端口：

```nginx
proxy_set_header Host $http_host;   # ✅
# proxy_set_header Host $host;      # ❌ 端口丢了，dsh 信任围栏直接 403
```

### 3. 目录 `/dev/shm`

容器/精简系统里跑 Chromium 系应用（QQ 等）会报 `Creating shared memory failed`，
需要挂载或创建 `/dev/shm` 并给 1777 权限。

### 4. `.htpasswd` 权限

nginx 读不到密码文件会返回 **500**（不是 401），日志里是
`open() "/www/wwwroot/dsh.htpasswd" failed (13: Permission denied)`。
归属要设成 `root:<nginx用户>`，权限 `640`。

### 5. dsh 每次重启都换 token

不是 bug。书签存根路径，别存带 token 的完整链接。

---

## 卸载

```bash
# 只拆服务和反代，聊天记录、工作区文件都留着（随时能装回来）
bash uninstall.sh

# 连数据一起清干净（不可恢复，会二次确认）
PURGE=1 bash uninstall.sh

# 先看看它会动什么，不实际执行
DRY_RUN=1 bash uninstall.sh
```

会依次处理：`dsh.service` → nginx 站点配置 → polyfill/密码文件/token 文件 →
全局 npm 包 → （可选）`$DSH_HOME` 与工作区。

> 卸载前建议先跑一次 `bash backup.sh`，数据虽然有保留，但备份永远不亏。

## 其它脚本

| 脚本 | 作用 |
|---|---|
| [install-qq.sh](install-qq.sh) | 把 dsh 接进 QQ（OneBot / NapCat 那套） |
| [install-plugins.sh](install-plugins.sh) | 装常用插件 |
| [doctor.sh](doctor.sh) | 体检：服务、端口、nginx、日志一把梭 |
| [uninstall.sh](uninstall.sh) | **一键卸载**（默认保留数据，`PURGE=1` 连数据一起删） |
| [backup.sh](backup.sh) | 备份 `$DSH_HOME` 和工作区 |
| [REINSTALL.md](REINSTALL.md) | 重装指南 |

---

## 已验证

| 项目 | 版本 |
|------|------|
| Ubuntu | 24.04.1 LTS，4 核 / 3.9G |
| Node | 22.23.4（精简版实测；完整版装 24.x） |
| dsh | 0.2.1-rc.2 |
| nginx | 1.24.0 |

实测项：页面加载 / `/api/*` 200 / WebSocket 101 正常收发 / polyfill 注入生效 /
Chrome 115 内核不再无限重连 / token 抓取正确。

---

MIT
