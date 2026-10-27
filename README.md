# 在服务器上养一个属于你自己的 鲸鱼娘

一套脚本，帮你在 Linux 服务器上把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（简称 dsh）装好、配好、能远程用。

装完之后你会得到：

- 🌐 **一个网页版deepseek harness鲸鱼娘**，浏览器打开就能聊，手机上也能用
- 🔒 **带密码保护**，别人打不开
- 💬 **（可选）接进 QQ**，用手机 QQ 就能找它，像跟朋友聊天
- 🐟 **（可选）给它一个性格**，不是冷冰冰的问答机器
- ⏰ **（可选）它会主动找你**，而不是永远等你开口

---

## 开始之前

### 你需要准备

| 东西 | 说明 | 必需 |
|---|---|---|
| 一台 Linux 服务器 | 云服务器就行，**内存 2G 以上**，硬盘 20G 以上 | ✅ |
| 一个 DeepSeek API Key | 去 [platform.deepseek.com](https://platform.deepseek.com/) 注册 → API keys → 创建 | ✅ |
| 会用一点点命令 | 其实全程只有「复制一条命令 → 粘贴 → 回车」 | ✅ |
| 一个 QQ 小号 | 想接 QQ 才需要。**强烈建议用小号**，有大号被风控的风险 | 可选 |

> 💰 费用：服务器钱 + DeepSeek 按用量付费（很便宜，日常聊天一个月几块钱）。

### 系统推荐

Ubuntu 22.04 / 24.04，或 Debian 12。

CentOS / Rocky 也能装，但软件源经常出问题，新手不建议。

---

## 第一步：连上服务器

如果你买的是云服务器，控制台里一般有「**远程连接**」或「**VNC / 网页终端**」按钮，点开就是一个黑窗口，可以直接用。

想用自己电脑连，见下面的附录 [怎么用 SSH](#附录a怎么用-ssh)。

连上后应该看到类似这样的提示符：

```
root@iZbp1xxxx:~#
```

看到 `#` 就说明你是管理员（root），可以开始装了。

---

## 第二步：一条命令装好 dsh

**复制下面这一整行**，粘贴到黑窗口里，回车：

```bash
PUBLIC_HOST=你的服务器公网IP \
  curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install.sh | bash
```

> 把 `你的服务器公网IP` 换成你服务器的 IP，比如 `38.76.185.196`。
> 不传的话脚本会用内网 IP，到时候浏览器打不开。

### 它会自己做完这些（你什么都不用管）

1. 装 Node.js（跑 dsh 需要）
2. 装 nginx（做反向代理 + 密码保护）
3. 如果内存小，自动开 2G 虚拟内存（swap），防止卡死
4. 设置时区为中国时间
5. 下载安装 dsh
6. 配置成开机自启、崩溃自动重启
7. 加一层「老浏览器兼容补丁」（不然旧手机浏览器会一直转圈）

整个过程 **3~10 分钟**，取决于网速。中途会刷很多字，正常。

### 装完你会看到

```
────────────────────────────────────────────────────────
 ✅ 部署完成

 本机地址   : http://127.0.0.1:3080
 对外地址   : http://你的IP:3081
 登录账号   : dsh
 登录密码   : xxxxxxxxxxxx
 工作区     : /www/wwwroot/dsh-workspace
 ...
 首次登录（token 换 cookie）：
   http://你的IP:3081/?token=xxxxxxxx
────────────────────────────────────────────────────────
```

**📌 把这三样抄到记事本里**：

1. 对外地址（`http://IP:3081`）
2. 账号密码
3. 那条带 `?token=` 的链接

> 密码也保存在服务器 `/www/wwwroot/dsh.credentials.txt`，忘了可以 `cat` 出来。

---

## 第三步：打开网页，填 API Key

### 1. 确认端口放行

去你的云服务器控制台，找到「**安全组**」或「**防火墙**」，放行 **3081** 端口（TCP）。

> 这一步经常被忘。网页打不开，90% 是这里没放行。

### 2. 浏览器打开

```
http://你的IP:3081
```

会先弹一个框要账号密码 —— 填上一步记下的 `dsh` 和那串密码。

然后**马上**把那条带 token 的链接也打开一次（同一个浏览器）：

```
http://你的IP:3081/?token=xxxxxxxx
```

> 为什么要多这一步？dsh 用「临时 token 换长期 cookie」来认人。打开一次 token 链接，之后就不用再带了。

### 3. 填 API Key

打开后点左下角 **设置** → **模型** → 填入你的 DeepSeek API Key → 保存。

现在回到主界面，新建一个会话，就可以开始聊了 🎉

---

## 第四步（可选）：接入 QQ

想用手机 QQ 找它，就继续。不想就跳到[第五步](#第五步可选给它性格和心跳)。

### 1. 跑一条命令

```bash
QQ_NUMBER=机器人QQ号 OWNER_QQ=你的QQ号 \
  bash <(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-qq.sh)
```

比如：

```bash
QQ_NUMBER=3214926616 OWNER_QQ=319085634 \
  bash <(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-qq.sh)
```

- `QQ_NUMBER`：**用来当机器人**的 QQ 号
- `OWNER_QQ`：**你本人**的 QQ 号（只有这个号能指挥它）

脚本会自动装好 QQ 协议端（NapCat）、配好通信、把插件挂上。

### 2. 扫码登录

脚本跑完会告诉你二维码在哪：

```
扫码登录：/www/wwwroot/napcat/napcat/cache/qrcode.png
```

把这个文件下载下来用手机 QQ 扫，或者在服务器上执行（如果装了图形界面）：

```bash
# 只看二维码路径的话
cat /var/log/napcat.log | grep 二维码
```

扫完在手机上点「确认登录」。

### 3. 确认登录成功

```bash
ss -lnt | grep 3001
```

看到 `LISTEN ... 127.0.0.1:3001` 就说明好了。

### 4. 重启让插件生效

```bash
systemctl restart dsh
```

### 5. 测试

用你的 QQ 给机器人发一句「你好」，几秒内应该会回复。

没动静的话看[常见问题](#qq-没反应)。

---

## 第五步（可选）：给它性格和心跳

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/install-plugins.sh)
systemctl restart dsh
```

装完刷新网页，**设置**里会多出两个页面：

- **人格**：用 Markdown 写「它是谁」。空着的话会自动用内置的「干饭鱼」人格 🐟
- **心跳**：让它定期醒来自言自语，决定要不要主动找你（不是无脑定时群发）

---

## 日常管理

| 想做什么 | 命令 |
|---|---|
| 看运行状态 | `systemctl status dsh` |
| 重启 | `systemctl restart dsh` |
| 停止 | `systemctl stop dsh` |
| 看日志 | `tail -f /var/log/dsh.log` |
| 看 QQ 协议端日志 | `tail -f /var/log/napcat.log` |
| 改网页密码 | 见下 |
| 升级 dsh | `npm i -g @deepseek-ai/dsh && systemctl restart dsh` |

### 改网页密码

```bash
# 生成新密码的哈希
openssl passwd -apr1 '你的新密码'

# 写进密码文件（把冒号后面那串换成上一步的输出）
echo 'dsh:刚才生成的哈希' > /www/wwwroot/dsh.htpasswd
chmod 640 /www/wwwroot/dsh.htpasswd

# 生效
nginx -s reload
```

---

## 常见问题

### 网页打不开

按顺序排查：

1. **云服务器安全组放行 3081 了吗？**（最常见）
2. 服务器上 nginx 起了吗：`systemctl status nginx`
3. dsh 起了吗：`systemctl status dsh`
4. 本机能不能访问：`curl -I http://127.0.0.1:3081/`（返回 401 是正常的，说明服务活着）

### 网页一直显示「重连中」

- **手机自带浏览器太老**（OPPO / vivo / 华为老机型）。换 Chrome、Edge、夸克。
- 脚本已经装了兼容补丁和心跳放宽，但太老的浏览器补不回来。
- 电脑上出现这个，检查网络是否稳定（WebSocket 对丢包敏感）。

### 提示「您的连接不是私密连接」

正常。现在是 HTTP 不是 HTTPS（没有域名，签不了证书）。点「高级」→「继续访问」即可。

想上 HTTPS 需要一个域名，然后 `certbot` 申请证书。

### QQ 没反应

按顺序查：

```bash
# 1. QQ 协议端活着吗
systemctl status napcat

# 2. OneBot 端口通吗
ss -lnt | grep 3001

# 3. 插件连上了吗
curl -s http://127.0.0.1:3002/api/qq/state | head -c 200

# 4. 日志里有没有报错
tail -50 /var/log/dsh.log | grep qq
```

常见原因：

- 你的 QQ 号不在白名单 → 只有 `OWNER_QQ` 那个号能指挥它
- 扫码过期了 → 重新 `systemctl restart napcat` 再扫
- 插件没加载 → `systemctl restart dsh`

### 内存不够 / 服务器卡死

```bash
free -h          # 看内存和 swap
```

dsh + QQ 协议端大概要 1~1.5G 内存。2G 机器必须开 swap（脚本会自动开）。

实在不够就升级配置，或者不装 QQ。

### 装到一半断了

重新跑同一条命令就行。脚本是**幂等**的：

- 已装的会跳过
- 已配的不会重复写
- 密码会复用，不会重置

---

## 卸载

```bash
systemctl disable --now dsh napcat
rm -rf /root/.dsh /www/wwwroot/dsh-workspace
rm -f /etc/systemd/system/dsh.service /etc/systemd/system/napcat.service
systemctl daemon-reload
npm uninstall -g @deepseek-ai/dsh
```

---

## 换服务器 / 重装系统

**先备份再动手**，否则人格、聊天记录、API Key 全没：

```bash
curl -fsSL https://raw.githubusercontent.com/zy666946/dsh-deploy/main/backup.sh | bash
scp -r root@旧服务器:/root/dsh-backup-* ./
```

到新机器上装好之后，再 `tar xzf` 还原。详细步骤见 [REINSTALL.md](REINSTALL.md)。

---

## 附录A：怎么用 SSH

### Windows

Win10 以上自带 SSH。按 `Win + R`，输入 `cmd`，回车，然后：

```bash
ssh root@你的服务器IP
```

第一次会问 `Are you sure you want to continue connecting?`，输入 `yes` 回车。

### Mac / Linux

打开「终端」，同样：

```bash
ssh root@你的服务器IP
```

### 连不上

- 确认 IP 没写错
- 确认服务器是「运行中」状态
- 云控制台的**安全组放行了 22 端口**（SSH）
- 密码错了会提示 `Permission denied`，去控制台重置密码

---

## 这个仓库里有什么

| 文件 | 作用 |
|---|---|
| `install.sh` | 装 dsh 本体（Node / nginx / 密码 / 兼容补丁）|
| `install-qq.sh` | 接 QQ（NapCat + OneBot + 插件）|
| `install-plugins.sh` | 装人格和心跳插件 |
| `backup.sh` | 重装前备份 |
| `REINSTALL.md` | 换机器 / 重装的完整步骤 |

## 相关项目

| 项目 | 说明 |
|---|---|
| [dsh](https://github.com/deepseek-ai/deepseek-harness) | 本体 |
| [dsh-qq](https://github.com/zy666946/dsh-qq) | QQ 接入插件 |
| [dsh-heartbeat-inner](https://github.com/zy666946/dsh-heartbeat-inner) | 主动心跳插件 |
| [dsh-agent-md](https://github.com/zy666946/dsh-agent-md) | 人格配置插件 |

## 许可

MIT
