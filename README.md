# PassWall One-Click Installer

适用于带传统 PassWall、Lua LuCI 和 Sing-Box/Xray 分流功能的 OpenWrt / iStoreOS。

当前修改基于并验证于：

- iStoreOS `25.12.6`
- PassWall `26.11.11-r1`
- x86_64

## Features

- 节点管理菜单聚合
- SOCKS5 节点批量导入
- 节点自动命名，例如 `socks5-node1`
- 节点分组、指定起始编号、清空已有节点
- SOCKS5 节点快速更改弹窗
- 节点列表一键 Ping、TCPing、URL 测试
- 一键勾选当前可见节点
- 测试时查询出口 IP 和中文城市
- 断网禁直连开关
- 内网 IP/CIDR 批量导入分流规则
- IP 范围一键生成，`①` 至 `④` 循环绑定 SOCKS5 节点
- 自动跳过已分配 IP
- 规则清理和配置备份
- LuCI 主题配色和自定义居中弹窗
- nftables hook 链恢复补丁
- Sing-box 黑洞出站补丁

## Repository Assets

- `install.sh`：主安装器、LuCI 页面和 UCI 导入逻辑
- `assets/passwall-node-list.htm`：增强后的节点列表页面
- `assets/passwall-nftables.sh`：nftables 基础链恢复补丁
- `assets/passwall-util_sing-box.lua`：黑洞默认出口兼容补丁

运行本地克隆中的安装器时会直接使用仓库资产；通过 `curl | sh` 方式运行时会从当前仓库下载资产。

## Install

```sh
curl -fsSL \
  -o /tmp/passwall-install.sh \
  https://raw.githubusercontent.com/404458478/passwall-oneclick/main/install.sh \
  && sh /tmp/passwall-install.sh
```

通过 SSH 安装：

```powershell
ssh root@ROUTER_IP "curl -fsSL -o /tmp/passwall-install.sh https://raw.githubusercontent.com/404458478/passwall-oneclick/main/install.sh && sh /tmp/passwall-install.sh"
```

## Usage

安装后进入：

```text
服务 -> PassWall -> 节点管理
服务 -> PassWall -> 批量导入分流规则
```

启用 SOCKS5 全局 TCP/UDP、DNS 和按客户端转发：

```sh
sh /tmp/passwall-install.sh --fix-sk5 223.5.5.5
```

移除自定义 LuCI 页面，不删除 PassWall 节点和分流规则：

```sh
sh /tmp/passwall-install.sh --uninstall
```

`--uninstall` 不会自动还原 `node_list.htm`、`nftables.sh` 和 `util_sing-box.lua`；安装时会在目标文件旁生成 `.bak.oneclick.*` 备份。

## Requirements

- root SSH access
- 传统 PassWall，不支持 PassWall2
- Lua LuCI
- Sing-Box/Xray 分流规则支持
- `curl`
- `lua`

## Security

- 安装器不包含路由器密码或 SOCKS5 凭据。
- 修改 UCI 配置前会创建 `/root/passwall.bak.*` 备份。
- 生产环境建议固定到 Git tag，不要直接跟随 `main`。
- 通过远程 URL 执行脚本前应先下载并检查内容。
