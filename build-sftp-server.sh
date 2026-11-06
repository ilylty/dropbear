#!/usr/bin/env bash
# Build a static musl sftp-server from OpenSSH sources, with the same Zig
# toolchain used by build.sh. Optional: dropbear only needs this for `sftp`.
#
# Everything is relative to this script's directory.
#   ./build-sftp-server.sh
#   TARGET=aarch64-linux-musl ./build-sftp-server.sh
set -eu

cd "$(dirname "$0")"

: "${OPENSSH_VERSION:=9.8p1}"
: "${ZIG_VERSION:=0.15.1}"
: "${JOBS:=8}"

if [ -z "${TARGET:-}" ]; then
  case "$(uname -m)" in
    x86_64)  TARGET="x86_64-linux-musl" ;;
    aarch64|arm64) TARGET="aarch64-linux-musl" ;;
    *) echo "Unsupported arch $(uname -m). Set TARGET explicitly." >&2; exit 1 ;;
  esac
fi

ROOT="$PWD"
CACHE="$ROOT/cache"
OUT="$ROOT/out"
WORK="$ROOT/build-sftp"

mkdir -p "$CACHE" "$OUT" "$WORK"

# ---------------------------------------------------------------- zig ------
zig_host_arch="$(uname -m)"
zig_pkg="zig-${zig_host_arch}-linux-${ZIG_VERSION}.tar.xz"
zig_dir="$CACHE/zig-${zig_host_arch}-linux-${ZIG_VERSION}"
if [ ! -x "$zig_dir/zig" ]; then
  if [ ! -f "$CACHE/$zig_pkg" ]; then
    echo "==> downloading $zig_pkg"
    curl -fL --retry 3 -o "$CACHE/$zig_pkg.part" \
      "https://ziglang.org/download/${ZIG_VERSION}/${zig_pkg}"
    mv "$CACHE/$zig_pkg.part" "$CACHE/$zig_pkg"
  fi
  tar -C "$CACHE" -xJf "$CACHE/$zig_pkg"
fi
ZIG="$zig_dir/zig"

# ------------------------------------------------------------- openssh -----
ossh_pkg="openssh-${OPENSSH_VERSION}.tar.gz"
if [ ! -f "$CACHE/$ossh_pkg" ]; then
  echo "==> downloading $ossh_pkg"
  curl -fL --retry 3 -o "$CACHE/$ossh_pkg.part" \
    "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/${ossh_pkg}"
  mv "$CACHE/$ossh_pkg.part" "$CACHE/$ossh_pkg"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
tar -C "$WORK" -xzf "$CACHE/$ossh_pkg"
SRC="$WORK/openssh-${OPENSSH_VERSION}"
cd "$SRC"

echo "==> configuring sftp-server only"
CC="$ZIG cc -target $TARGET" \
./configure \
  --host="$TARGET" \
  --without-openssl \
  --without-zlib \
  --without-pam \
  --disable-etc-default-login \
  --disable-strip

echo "==> compiling sftp-server"
make -j "$JOBS" sftp-server

[ -x ./sftp-server ] || { echo "BUILD FAILED: sftp-server missing" >&2; exit 1; }
strip ./sftp-server || true
file ./sftp-server || true

stage="$WORK/stage/sftp-server-${TARGET}"
mkdir -p "$stage"
cp ./sftp-server "$stage/"
out="$OUT/sftp-server-${TARGET}.tar.xz"
tar -C "$WORK/stage" -cJf "$out" "sftp-server-${TARGET}"
( cd "$OUT" && sha256sum "$(basename "$out")" > "$(basename "$out").SHA256" )
echo "==> wrote $out"
