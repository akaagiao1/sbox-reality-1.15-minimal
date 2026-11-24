# sbox-reality-1.15-minimal

合租节点管理：**按用户**（不是按节点）计流量、管到期、自动踢人。

架构很干净，分两层：

1. **sing-box（源码编译，带 `with_v2ray_api`）**：三个共享入站（ss / VLESS+Reality / Snell v6），每个合租人是入站 `users` 里的一个 `name`；V2Ray API 按用户名统计上行+下行。
2. **本地定时脚本（`sbox-traffic check`，每 5 分钟）**：采样 V2Ray API、累计流量、30 天周期重置、Telegram 提醒、额度用完或到期自动踢人（把用户从配置里去掉并重启 sing-box）。

支持 Debian / Ubuntu（systemd）和 Alpine（OpenRC），使用 root 运行。当前配置已在 sing-box **1.15.0-alpha.13** 验证，安装时获取最新 Alpha。

## 首次安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akaagiao1/sbox-reality-1.15-minimal/main/install.sh) --setup
```

Alpine 先执行 `apk add --no-cache bash curl`。

安装默认获取最新 Alpha。需要固定版本时，下载脚本并指定完整版本号：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/akaagiao1/sbox-reality-1.15-minimal/main/install.sh
bash install.sh --setup --version 1.15.0-alpha.13
```

安装过程：检测系统 → 装依赖（Go、grpcurl、jq、curl）→ 从源码编译 sing-box（带 `with_v2ray_api`，并验证编译出的二进制确实支持 V2Ray API）→ 生成服务端配置与 Reality 密钥 → 装 systemd/OpenRC 服务 → 提示配置 Telegram。

按提示配置 Telegram，然后运行管理菜单：

```bash
sbox-node
```

日常操作都在菜单中完成：添加用户、查看客户端配置、调整额度、续期、暂停、恢复和删除。

## 添加用户

推荐使用菜单选项 **1**。命令行示例：

```bash
# 添加合租人 alice：额度 100G / 30 天，到期 2026-12-31
sbox-node user add alice --quota 100G --expires 2026-12-31

# 不限额度、不限到期
sbox-node user add bob --quota 0
```

每个用户在三个协议上是**同一份额度、同一份到期**：ss、VLESS+Reality、Snell v6 三个入站共享该用户的流量统计（V2Ray API 按用户名汇总三个入站的上行+下行）。

- **周期固定 30 天**：从用户创建时起算，满 30 天自动清零并重开周期。
- **额度按 GB**：支持 `100`、`100G`、`100GB`、`1.5T` 写法，`0` 表示不限。
- 额度用完或到期，定时检查会自动把该用户从三个入站里去掉并重启 sing-box（踢人）；续费/加额度/重置流量后自动恢复。

| 协议 | sing-box 客户端 | Surge |
| --- | --- | --- |
| `ss`（2022-blake3-aes-128-gcm，多用户） | 支持 | 支持 |
| `vless`（VLESS + Reality + xtls-rprx-vision） | 支持 | 不支持 |
| `snell`（Snell v6，userkey 多用户） | 支持 | 需要支持 v6 userkey 的版本 |

注意：

- ss 多用户客户端密码格式为 `server_password:user_password`（冒号连接），`sing-box.json`、`surge.conf`、`url.txt` 里已按此格式生成，直接用即可。
- Snell v6 多用户使用 `userkey`（每个用户独立 userkey，PSK 全站共用）；Surge 的 Snell 需支持 v6 `userkey` 的版本。
- VLESS+Reality 客户端 outbound 已含 `utls: {enabled: true, fingerprint: "chrome"}`（Reality 客户端必需）。

## 查看用户配置

菜单选项 **2：查看用户 / 客户端配置**，然后选择用户，即可复制该用户的 Surge、sing-box 配置和分享链接。输入 `0` 返回。

也可以直接查看：

```bash
sbox-node user list
sbox-node user clients alice
```

每个用户的文件单独保存在：

```text
/root/sbox-reality/clients/<用户名>/
  sing-box.json
  surge.conf       # ss 和 snell（Surge 不支持 VLESS+Reality）
  url.txt
  info.txt
```

sing-box 输出是 `outbounds` 片段，合并到客户端原配置中即可。配置包含连接凭据，请按用户分别分发。

## 日常管理

```bash
sbox-node traffic show                         # 查看流量和到期状态
sbox-node user set alice --quota 200G          # 修改额度
sbox-node user set alice --expires 2027-03-31 # 续期
sbox-node traffic reset alice                  # 重置已用流量，开始新 30 天周期
sbox-node traffic pause alice                  # 手动暂停
sbox-node traffic resume alice                 # 取消手动暂停
sbox-node user remove alice                    # 删除用户
sbox-node notify test                          # 测试 Telegram
```

Telegram 配置只需保存一次，支持多个 Chat ID：

```bash
sbox-node notify setup 'BOT_TOKEN' 'CHAT_ID_1,CHAT_ID_2'
```

通知包括额度达到 80%、额度用完、到期前 7/3/1 天、已到期及恢复可用。VPS 防火墙和云安全组需放行三个入站端口。

## 定时检查

安装后自动装好定时任务：

- systemd：`sbox-traffic.service` + `sbox-traffic.timer`（每 5 分钟）
- OpenRC：crontab `*/5 * * * * /usr/local/sbin/sbox-traffic check`

每次检查：采样 V2Ray API → 与上次计数器做差分累计（sing-box 重启导致计数器回落时按当前值计）→ 满 30 天清零 → 判断额度/到期 → 发 Telegram 提醒 → 有用户被踢/恢复时才重渲染配置并重启 sing-box（配置没变不重启）。

手动跑一次：

```bash
sbox-node traffic check
# 或
sbox-traffic check
```

## 状态文件

```text
/etc/sbox-reality/
  users.json            # 服务端端口、密钥与用户列表（额度、到期、凭据）
  traffic/state.json    # 每用户已用流量、上次计数器、周期起点、暂停原因、提醒标记
  notify.env            # Telegram Bot Token 与 Chat ID（600 权限）
/etc/sing-box/config.json   # 服务端配置（由 sbox-node 渲染，勿手工改）
```

## 已知限制

- VLESS+Reality 的握手验证依赖目标站点的真实 TLS（`reality_domain` 默认 `www.apple.com`）；沙箱/代理拦截 TLS 的环境里 Reality 握手可能失败，属环境限制，生产 VPS 上正常。
- Surge 的 Snell 多用户需要支持 v6 `userkey` 的版本；不支持时只用 ss 或 sing-box 客户端。
- 编译 sing-box 需要约 1GB 可用内存；`go build` 中间文件放在构建目录内，不占 `/tmp`。

基于 [sbox-reality](https://github.com/akaagiao1/sbox-reality/tree/codex/multi-tenant-traffic)，保留原项目历史及 **AGPL-3.0** 许可证。
