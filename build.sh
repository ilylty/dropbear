#!/usr/bin/env bash
# Build static Dropbear (musl) with the android-passwd patch applied.
# This is the script GitHub Actions runs; it is also usable locally.
# Everything is relative to this script's directory.
#
#   ./build.sh
#   TARGET=aarch64-linux-musl ./build.sh
#   DROPBEAR_VERSION=2025.88 ZIG_VERSION=0.15.1 ./build.sh
#
# Output: ./out/dropbear-<target>.tar.xz (+ .SHA256)
set -eu

cd "$(dirname "$0")"

: "${DROPBEAR_VERSION:=2025.88}"
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
WORK="$ROOT/build"

# The patch may live in ./patches/ (standalone layout) or ./ (repo root layout)
PATCH=""
for cand in "$ROOT/patches/android-passwd-support.patch" \
            "$ROOT/android-passwd-support.patch"; do
  if [ -f "$cand" ]; then PATCH="$cand"; break; fi
done
if [ -z "$PATCH" ]; then
  echo "ERROR: android-passwd-support.patch not found." >&2
  echo "       Looked in ./patches/ and ./" >&2
  exit 1
fi

mkdir -p "$CACHE" "$OUT"
echo "==> target: $TARGET  (dropbear $DROPBEAR_VERSION, zig $ZIG_VERSION)"
echo "==> patch : $PATCH"

# ---------------------------------------------------------------- zig ------
zig_host_arch="$(uname -m)"
zig_pkg="zig-${zig_host_arch}-linux-${ZIG_VERSION}.tar.xz"
zig_dir="$CACHE/zig-${zig_host_arch}-linux-${ZIG_VERSION}"

if [ ! -x "$zig_dir/zig" ]; then
  if [ ! -f "$CACHE/$zig_pkg" ]; then
    echo "==> downloading $zig_pkg"
    curl -fL --retry 3 --retry-delay 2 \
      -o "$CACHE/$zig_pkg.part" \
      "https://ziglang.org/download/${ZIG_VERSION}/${zig_pkg}"
    mv "$CACHE/$zig_pkg.part" "$CACHE/$zig_pkg"
  fi
  echo "==> extracting zig"
  tar -C "$CACHE" -xJf "$CACHE/$zig_pkg"
fi
ZIG="$zig_dir/zig"
echo "==> zig: $("$ZIG" version)"

# ----------------------------------------------------------- dropbear ------
db_pkg="dropbear-${DROPBEAR_VERSION}.tar.bz2"
if [ ! -f "$CACHE/$db_pkg" ]; then
  echo "==> downloading $db_pkg"
  curl -fL --retry 3 --retry-delay 2 \
    -o "$CACHE/$db_pkg.part" \
    "https://matt.ucc.asn.au/dropbear/releases/${db_pkg}"
  mv "$CACHE/$db_pkg.part" "$CACHE/$db_pkg"
fi

rm -rf "$WORK"
mkdir -p "$WORK"
tar -C "$WORK" -xjf "$CACHE/$db_pkg"
SRC="$WORK/dropbear-${DROPBEAR_VERSION}"
cd "$SRC"

# ------------------------------------------------------------- patch -------
echo "==> applying $(basename "$PATCH")"
patch -p1 --forward < "$PATCH"

# patch must have landed, otherwise the build is useless for Android
if ! grep -q 'ANDROID_PASSWD_FILE' src/default_options.h; then
  echo "ERROR: patch applied but ANDROID_PASSWD_FILE missing" >&2
  exit 1
fi

# ------------------------------------------------------------- build -------
echo "==> configuring"
CC="$ZIG cc -target $TARGET" \
CFLAGS="-Os -fno-pie" \
LDFLAGS="-static -no-pie" \
CPPFLAGS="-DDROPBEAR_X11FWD" \
./configure \
  --host="$TARGET" \
  --disable-pam \
  --disable-zlib \
  --enable-bundled-libtom \
  --enable-static \
  --disable-lastlog \
  --disable-utmp \
  --disable-utmpx \
  --disable-wtmp \
  --disable-wtmpx \
  --disable-loginfunc \
  --disable-pututline \
  --disable-pututxline

echo "==> compiling"
make -j "$JOBS" PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" STATIC=1

for f in dropbear dbclient dropbearkey dropbearconvert scp; do
  [ -x "./$f" ] || { echo "BUILD FAILED: $f missing" >&2; exit 1; }
done

# sanity: the patched options must be present in -h output
./dropbear -h 2>&1 | grep -q -- '-y PasswdFile' || {
  echo "BUILD FAILED: -y option missing (patch not applied?)" >&2; exit 1; }
./dropbear -h 2>&1 | grep -q -- '-Y SftpPath' || {
  echo "BUILD FAILED: -Y option missing (patch not applied?)" >&2; exit 1; }

echo "==> stripping"
strip ./dropbear ./dbclient ./dropbearkey ./dropbearconvert ./scp || true
file ./dropbear || true

# ----------------------------------------------------------- package -------
stage="$WORK/stage/dropbear-${TARGET}"
mkdir -p "$stage"
cp ./dropbear ./dbclient ./dropbearkey ./dropbearconvert ./scp "$stage/"
cp "$PATCH" "$stage/" 2>/dev/null || true

db_out="$OUT/dropbear-${TARGET}.tar.xz"
tar -C "$WORK/stage" -cJf "$db_out" "dropbear-${TARGET}"
( cd "$OUT" && sha256sum "$(basename "$db_out")" > "$(basename "$db_out").SHA256" )
echo "==> wrote $db_out"

# ------------------------------------------------------ sftp-server --------
if [ -x "$ROOT/build-sftp-server.sh" ] && [ "${SKIP_SFTP:-0}" != "1" ]; then
  echo "==> building sftp-server"
  ( cd "$ROOT" && TARGET="$TARGET" ZIG_VERSION="$ZIG_VERSION" JOBS="$JOBS" \
      ./build-sftp-server.sh ) || echo "==> sftp-server build failed (optional)" >&2
fi

echo
echo "Done."
ls -l "$OUT"
