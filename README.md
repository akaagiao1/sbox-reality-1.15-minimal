# sbox-reality-1.15-minimal

用于 **多用户、多协议节点管理** 的 sing-box 脚本。每个节点有独立端口、凭据、流量额度和到期时间；同一用户可以创建多个协议节点。

支持 Debian / Ubuntu 和 Alpine，使用 root 运行。当前配置已在 sing-box **1.15.0-alpha.12** 验证，安装时获取最新 Alpha。

## 首次安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/akaagiao1/sbox-reality-1.15-minimal/main/install.sh) --setup
```

Alpine 先执行 `apk add --no-cache bash curl`。

安装默认获取最新 Alpha。需要固定版本时，下载脚本并指定完整版本号：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/akaagiao1/sbox-reality-1.15-minimal/main/install.sh
bash install.sh --setup --version 1.15.0-alpha.12
```

安装失败会尝试恢复升级前的程序、运行文件、配置和服务状态。Debian/Ubuntu 的 dpkg 软件包数据库不随文件恢复回滚；出现相关警告时，应重新安装所需版本以同步软件包状态。

按提示配置 Telegram，然后运行管理菜单：

```bash
sbox-node
```

日常操作都在菜单中完成：添加用户节点、查看客户端配置、调整额度、续期、暂停、恢复和删除。

## 添加用户节点

推荐使用菜单选项 **1**。命令行示例：

```bash
# 同一用户创建 Snell v6 和 VLESS 两个节点
sbox-node node add alice-snell6 snell6 --customer alice --port auto \
  --quota 100G --reset-day 1 --expires 2026-12-31

sbox-node node add alice-vless vless --customer alice --port auto \
  --quota 100G --reset-day 1 --expires 2026-12-31
```

`alice` 是用户 ID；`alice-snell6`、`alice-vless` 是唯一的节点 ID。**额度按节点分别统计，不合并为用户总额度**，统计上行与下行总流量，月度重置日支持 `1–28`。额度用完或到期会暂停该节点。

额度支持 `B/K/M/G/T/P`（也可使用 `GiB` 等形式）和小数，`0` 表示不限。为保证 JSON 和计算精度，最大支持 `9007199254740991` 字节；不支持 `E/EB/EiB`，正额度不得小于 1 字节。

| 协议参数 | sing-box 客户端 | Surge |
| --- | --- | --- |
| `snell5` | 支持 | 支持 |
| `snell6` | 支持 | 需要支持 v6 的版本 |
| `hy2` | 支持 | 支持 |
| `anytls` | AnyTLS + REALITY | 不支持该组合 |
| `vless` | VLESS + REALITY | 不支持 |
| `direct` | 固定目标中转，不生成客户端代理配置 | — |

## 查看用户配置

菜单选项 **2：查看所有节点 / 客户端配置**，然后选择节点，即可复制该节点的 Surge、sing-box 配置和分享链接。输入 `0` 返回。

也可以直接查看：

```bash
sbox-node node list
sbox-node node clients alice-snell6
```

查看优先使用已保存的配置，不改变凭据。需要重新生成文件时：

```bash
sbox-node node regen alice-snell6
```

每个节点的文件单独保存在：

```text
/root/sbox-reality/clients/<节点ID>/
  sing-box.json
  surge.conf       # 支持 Surge 的协议
  url.txt
  info.txt
```

sing-box 输出是 `outbounds` 片段，合并到客户端原配置中即可。配置包含连接凭据，请按用户分别分发。

## 日常管理

```bash
sbox-node traffic show                              # 查看流量和到期状态
sbox-node traffic set alice-snell6 --quota 200G      # 修改额度
sbox-node traffic set alice-snell6 --expires 2027-03-31 # 续期
sbox-node traffic reset alice-snell6                 # 重置已用流量
sbox-node traffic pause alice-snell6                 # 手动暂停
sbox-node traffic resume alice-snell6                # 取消手动暂停
sbox-node node port alice-snell6 25001                # 修改端口
sbox-node node remove alice-snell6                    # 删除节点
sbox-node notify test                                # 测试 Telegram
```

Telegram 配置只需保存一次，支持多个 Chat ID：

```bash
sbox-node notify setup 'BOT_TOKEN' 'CHAT_ID_1,CHAT_ID_2'
```

通知包括额度达到 80%、额度用完、到期提醒及恢复可用。VPS 防火墙和云安全组需放行节点端口。

## 可选 WARP 分流

下载脚本后配置规则；不需要重装客户节点：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/akaagiao1/sbox-reality-1.15-minimal/main/install.sh
bash install.sh --warp-rules youtube,netflix
bash install.sh --warp-off
```

规则来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat/tree/sing)，WARP 私钥保存在 `/etc/sing-box/sbox-warp-credentials.credentials`。

普通新配置只生成 `inbounds`；启用 WARP 时才增加必要的出站、WireGuard endpoint 和路由。增量操作保留已有自定义配置。

管理状态位于 `/etc/sbox-reality/`，服务端配置位于 `/etc/sing-box/config.json`。已知限制见 [审查报告](docs/REVIEW.md)。

基于 [sbox-reality](https://github.com/akaagiao1/sbox-reality/tree/codex/multi-tenant-traffic)，保留原项目历史及 **AGPL-3.0** 许可证。
