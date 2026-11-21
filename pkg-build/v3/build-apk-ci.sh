#!/bin/sh
# Build apk for luci-app-passwall-socks5-batch on Ubuntu / GitHub Actions.
# Uses Alpine apk-tools-static (mkpkg) which OpenWrt's apk does not ship.
#
# usage: sh pkg-build/v3/build-apk-ci.sh <version>
#   optional env: WORK (default /tmp/apkbuild), ATS_VER (default 3.0.10-r1)
set -eu

VERSION="${1:?usage: build-apk-ci.sh <version>  e.g. 26.11.21-r5}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/apkbuild}"
ATS_VER="${ATS_VER:-3.0.10-r1}"
ATS_URL="https://dl-cdn.alpinelinux.org/alpine/edge/main/x86_64/apk-tools-static-${ATS_VER}.apk"

NAME=luci-app-passwall-socks5-batch
INSTALL_SH="$ROOT_DIR/install.sh"
SCRIPTS_DIR="$ROOT_DIR/pkg-build/v3"
DIST="$ROOT_DIR/dist"

[ -s "$INSTALL_SH" ] || { echo "missing $INSTALL_SH" >&2; exit 1; }
[ -s "$SCRIPTS_DIR/post-install" ] || { echo "missing post-install" >&2; exit 1; }

mkdir -p "$WORK" "$DIST"

if [ ! -x "$WORK/sbin/apk.static" ]; then
    echo "== download apk-tools-static ${ATS_VER} =="
    curl -fsSL --retry 3 --max-time 180 -o "$WORK/apk-tools-static.apk" "$ATS_URL"
    tar -xzf "$WORK/apk-tools-static.apk" -C "$WORK"
fi
A="$WORK/sbin/apk.static"
[ -x "$A" ] || { echo "apk.static not found in $WORK" >&2; exit 1; }
"$A" --version | head -n 1

PKG_ROOT="$WORK/root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/usr/share/passwall-socks5-batch"
cp "$INSTALL_SH" "$PKG_ROOT/usr/share/passwall-socks5-batch/install.sh"
chmod 0755 "$PKG_ROOT/usr/share/passwall-socks5-batch/install.sh"
chmod 0755 "$SCRIPTS_DIR/post-install" "$SCRIPTS_DIR/post-upgrade" "$SCRIPTS_DIR/pre-deinstall"

OUT="$DIST/$NAME-$VERSION.apk"
rm -f "$OUT" "$OUT.sha256"
"$A" mkpkg \
    --info "name:$NAME" \
    --info "version:$VERSION" \
    --info "description:Offline PassWall SOCKS5 node management and batch import extension" \
    --info "arch:x86_64" \
    --info "license:MIT" \
    --info "origin:$NAME" \
    --info "url:https://github.com/404458478/passwall-oneclick" \
    --info "maintainer:404458478" \
    --info "depends:luci-app-passwall lua" \
    --script "post-install:$SCRIPTS_DIR/post-install" \
    --script "post-upgrade:$SCRIPTS_DIR/post-upgrade" \
    --script "pre-deinstall:$SCRIPTS_DIR/pre-deinstall" \
    --files "$PKG_ROOT" \
    --output "$OUT"

( cd "$DIST" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
( cd "$DIST" && sha256sum "$(basename "$OUT")" > SHA256SUMS )
echo "== built =="
ls -l "$OUT"
cat "$OUT.sha256"
