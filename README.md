# PassWall SOCKS5 批量扩展（passwall-oneclick）

PassWall 的节点批量管理 / 批量导入分流规则扩展，附 DNS检测（节点当地 DNS 强制接管）、IP可用性检测、
节点列表分页搜索排序、快速更改节点等增强。

离线安装包与安装脚本的发布仓库，**每个版本单独保留，不覆盖旧版本**。

## 目录结构

    install.sh                      一键安装/卸载脚本（离线自包含）
    assets/                         脚本使用的资源文件
      passwall-node-list.htm        节点列表页面
      passwall-nftables.sh          nftables 补丁（DNS检测）
      passwall-util_sing-box.lua    PassWall 原版工具库
    releases/<版本>/                正式版本（APK + SHA256）
    dev/<版本>/                     开发版本（每次构建单独保留）
    pkg-build/v3/                   打包脚本
      build-apk-ci.sh               GitHub Actions 使用的构建脚本
      post-install                  安装后执行 install.sh
      post-upgrade                  升级后执行 install.sh
      pre-deinstall                 卸载时执行 install.sh --uninstall
    .github/workflows/build-apk.yml 自动打包 / 发布工作流
    SHA256SUMS                      全部文件校验值

## 版本历史

| 版本 | 说明 |
|---|---|
| 26.11.20-r5 | 初版离线包（基础批量管理 + DNS 防泄漏） |
| 26.11.21-r1 | DNS检测 / IP可用性检测 / 分页 / 弹窗等界面增强 |
| 26.11.21-r2 | 主开关统一控制 DNS 接管启停 |
| 26.11.21-r3 | 安装后主开关默认关闭 |
| 26.11.21-r4 | 修复默认关闭时仍残留代理与 nft 规则 |
| 26.11.21-r5 | 卸载安全还原 PassWall 原版页面（当前正式版） |
| 26.11.21-dev1 | 开发版（内容同 r5，开发渠道首个构建） |

## 安装

    apk add --allow-untrusted luci-app-passwall-socks5-batch-26.11.21-r5.apk

或直接运行脚本：

    sh install.sh

安装完成后打开 LuCI：服务 -> PassWall -> 节点管理 / 批量导入分流规则。

## 卸载

    apk del luci-app-passwall-socks5-batch

或：

    sh install.sh --uninstall

卸载会还原 PassWall 原版文件（节点列表模板有持久备份与内置兜底，保证页面不损坏），
节点与分流规则数据保留。

## 行为说明

- 安装后 PassWall 主开关默认关闭，代理和 DNS 接管都不运行。
- 打开主开关后，自动启动 DNS 接管守护进程并加载 DNS检测 的 nft 规则。
- 关闭主开关后，自动停止守护进程并清理规则。
- 节点列表支持分页、搜索、排序、单选更改节点；分流规则表新增 DNS检测 列。

## GitHub Actions 自动打包 APK

仓库已内置工作流 `.github/workflows/build-apk.yml` 与构建脚本 `pkg-build/v3/build-apk-ci.sh`。

触发方式：

1. 打标签推送（自动创建 Release 并上传 APK）：

       git tag v26.11.21-r6
       git push origin v26.11.21-r6

2. 手动触发：Actions -> build-apk -> Run workflow，填入版本号（例如 26.11.21-r6），
   产物在该次运行的 Artifacts 中（手动运行不会创建 Release）。

构建过程：

1. 下载 Alpine apk-tools-static 3.0.10-r1（提供 mkpkg）
2. 把 install.sh 装入包路径 `/usr/share/passwall-socks5-batch/install.sh`
3. 生成 `luci-app-passwall-socks5-batch-<版本>.apk` 及 `.sha256`、`SHA256SUMS`
4. 标签触发时由 softprops/action-gh-release 上传到对应 Release

## 仓库

https://github.com/ssxadn/passwall-oneclick
