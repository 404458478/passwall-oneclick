# PassWall SOCKS5 批量扩展（passwall-oneclick）

离线安装包 / 安装脚本发布仓库。每个版本单独保留，不覆盖旧版本。

## 目录

    install.sh                    最新安装/卸载脚本
    assets/                       脚本使用的资源文件（节点列表页 / nftables / util）
    releases/<版本>/              正式版本（APK + SHA256）
    dev/<版本>/                   开发版本（每次构建单独保留）

## 版本历史

| 版本 | 说明 |
|---|---|
| 26.11.20-r5 | 初版离线包（基础批量管理 + DNS 防泄漏） |
| 26.11.21-r1 | DNS检测 / IP可用性检测 / 分页 / 弹窗等 UI |
| 26.11.21-r2 | 主开关统一控制 DNS 接管启停 |
| 26.11.21-r3 | 安装后主开关默认关闭 |
| 26.11.21-r4 | 修复默认关闭时仍残留代理/nft 规则 |
| 26.11.21-r5 | 卸载安全还原 PassWall 原版模板（当前最新） |
| 26.11.21-dev1 | 开发版（同 r5 内容，开发渠道首个构建） |

## 安装

    apk add --allow-untrusted luci-app-passwall-socks5-batch-26.11.21-r5.apk

或：

    sh install.sh

卸载：

    apk del luci-app-passwall-socks5-batch

## 行为

- 安装后 PassWall 主开关默认关闭。
- 打开主开关：自动启动 DNS 接管守护并加载 DNS检测 nft 规则。
- 关闭主开关：自动停止守护并清理规则。
- 卸载会还原 PassWall 原版文件（节点列表模板有持久备份 + 内置兜底）。