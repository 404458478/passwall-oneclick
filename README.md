# PassWall SOCKS5 One-Click Installer

适用于带传统 PassWall、Lua LuCI 和 Sing-Box/Xray 分流功能的 OpenWrt / iStoreOS。

## Features

- SOCKS5 node batch import
- SOCKS5 availability check with inline repair
- SOCKS5 batch delete
- Internal IP/CIDR batch import
- Internal IP/CIDR batch delete
- Round-robin binding to imported SOCKS5 nodes
- Xray source-only rule compatibility fix

## Install

Replace `YOUR_GITHUB_USER` with the GitHub account that owns the repository.

```sh
curl -fsSL \
  -o /tmp/passwall-install.sh \
  https://raw.githubusercontent.com/YOUR_GITHUB_USER/passwall-oneclick/main/install.sh \
  && sh /tmp/passwall-install.sh
```

Mirror CDN:

```sh
curl -fsSL \
  -o /tmp/passwall-install.sh \
  https://cdn.jsdelivr.net/gh/YOUR_GITHUB_USER/passwall-oneclick@main/install.sh \
  && sh /tmp/passwall-install.sh
```

Run from a Windows SSH client:

```powershell
ssh root@ROUTER_IP "curl -fsSL -o /tmp/passwall-install.sh https://raw.githubusercontent.com/YOUR_GITHUB_USER/passwall-oneclick/main/install.sh && sh /tmp/passwall-install.sh"
```

## Usage

After installation, open:

```text
Services -> PassWall -> SOCKS5 Batch Import
Services -> PassWall -> Internal IP Import
```

Apply the SK5 compatibility settings without reinstalling:

```sh
sh /tmp/passwall-install.sh --fix-sk5 223.5.5.5
```

Remove the custom LuCI pages without deleting PassWall nodes or routing rules:

```sh
sh /tmp/passwall-install.sh --uninstall
```

## Requirements

- root SSH access
- traditional PassWall with `luci.passwall.api`
- Lua LuCI
- `lua`
- `curl`
- Sing-Box/Xray shunt-rule support

## Security

- Download the script before executing it.
- Verify `SHA256SUMS` when deploying a release.
- Pin production installs to a Git tag instead of `main`.
- The installer does not contain router passwords or SOCKS5 credentials.
