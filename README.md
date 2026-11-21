# PassWall SOCKS5 鎵归噺鎵╁睍锛坧asswall-oneclick锛?
绂荤嚎瀹夎鍖?/ 瀹夎鑴氭湰鍙戝竷浠撳簱銆傛瘡涓増鏈崟鐙繚鐣欙紝涓嶈鐩栨棫鐗堟湰銆?
## 鐩綍

    install.sh                    鏈€鏂板畨瑁?鍗歌浇鑴氭湰
    assets/                       鑴氭湰浣跨敤鐨勮祫婧愭枃浠讹紙鑺傜偣鍒楄〃椤?/ nftables / util锛?    releases/<鐗堟湰>/              姝ｅ紡鐗堟湰锛圓PK + SHA256锛?    dev/<鐗堟湰>/                   寮€鍙戠増鏈紙姣忔鏋勫缓鍗曠嫭淇濈暀锛?
## 鐗堟湰鍘嗗彶

| 鐗堟湰 | 璇存槑 |
|---|---|
| 26.11.20-r5 | 鍒濈増绂荤嚎鍖咃紙鍩虹鎵归噺绠＄悊 + DNS 闃叉硠婕忥級 |
| 26.11.21-r1 | DNS妫€娴?/ IP鍙敤鎬ф娴?/ 鍒嗛〉 / 寮圭獥绛?UI |
| 26.11.21-r2 | 涓诲紑鍏崇粺涓€鎺у埗 DNS 鎺ョ鍚仠 |
| 26.11.21-r3 | 瀹夎鍚庝富寮€鍏抽粯璁ゅ叧闂?|
| 26.11.21-r4 | 淇榛樿鍏抽棴鏃朵粛娈嬬暀浠ｇ悊/nft 瑙勫垯 |
| 26.11.21-r5 | 鍗歌浇瀹夊叏杩樺師 PassWall 鍘熺増妯℃澘锛堝綋鍓嶆渶鏂帮級 |
| 26.11.21-dev1 | 寮€鍙戠増锛堝悓 r5 鍐呭锛屽紑鍙戞笭閬撻涓瀯寤猴級 |

## 瀹夎

    apk add --allow-untrusted luci-app-passwall-socks5-batch-26.11.21-r5.apk

鎴栵細

    sh install.sh

鍗歌浇锛?
    apk del luci-app-passwall-socks5-batch

## 琛屼负

- 瀹夎鍚?PassWall 涓诲紑鍏抽粯璁ゅ叧闂€?- 鎵撳紑涓诲紑鍏筹細鑷姩鍚姩 DNS 鎺ョ瀹堟姢骞跺姞杞?DNS妫€娴?nft 瑙勫垯銆?- 鍏抽棴涓诲紑鍏筹細鑷姩鍋滄瀹堟姢骞舵竻鐞嗚鍒欍€?- 鍗歌浇浼氳繕鍘?PassWall 鍘熺増鏂囦欢锛堣妭鐐瑰垪琛ㄦā鏉挎湁鎸佷箙澶囦唤 + 鍐呯疆鍏滃簳锛夈€
## GitHub Actions 自动打包 APK

仓库已内置工作流 `.github/workflows/build-apk.yml` 与构建脚本 `pkg-build/v3/build-apk-ci.sh`。

触发方式：

1. 打标签推送（自动创建 Release 并上传 APK）：
       git tag v26.11.21-r5
       git push origin v26.11.21-r5
2. 手动触发：Actions -> build-apk -> Run workflow，填入版本号（如 26.11.21-r5），产物在 Artifacts。

构建过程：下载 Alpine apk-tools-static 3.0.10-r1，用 mkpkg 把 `install.sh` 打成
`luci-app-passwall-socks5-batch-<版本>.apk`，并生成 `.sha256` 与 `SHA256SUMS`。