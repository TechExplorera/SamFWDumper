#!/usr/bin/env bash
# Compila erofs-utils (upstream, kernel.org) + lz4 como binarios estáticos de Android
# y los deja en android/app/src/main/jniLibs/<abi>/lib<herramienta>.so
#
# Uso: tool/build_android_tools.sh <ANDROID_NDK_HOME> [abi=arm64-v8a]
set -euo pipefail

NDK="${1:?ruta al NDK}"
ABI="${2:-arm64-v8a}"
API=29
EROFS_TAG=v1.9.4
LZ4_TAG=v1.10.0

case "$ABI" in
  arm64-v8a) TRIPLE=aarch64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi ;;
  x86_64) TRIPLE=x86_64-linux-android ;;
  *) echo "ABI no soportada: $ABI" >&2; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/android/app/src/main/jniLibs/$ABI"
WORK="${WORK:-$HERE/build/tools-src}"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
export CC="$TC/${TRIPLE}${API}-clang"
export AR="$TC/llvm-ar"
export RANLIB="$TC/llvm-ranlib"
export STRIP="$TC/llvm-strip"

mkdir -p "$WORK" "$OUT"
cd "$WORK"

[ -d lz4 ] || git clone -q --depth 1 --branch "$LZ4_TAG" https://github.com/lz4/lz4.git
[ -d erofs-utils ] || git clone -q --depth 1 --branch "$EROFS_TAG" https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git

echo "== lz4 ($ABI)"
make -s -C lz4/lib clean >/dev/null || true
rm -f lz4/lib/liblz4.so* && make -s -C lz4/lib liblz4.a CC="$CC" AR="$AR" CFLAGS="-O2 -fPIC"

echo "== erofs-utils $EROFS_TAG ($ABI)"
cd erofs-utils
[ -x configure ] || ./autogen.sh >/dev/null
make -s distclean >/dev/null 2>&1 || true
# Sin pkg-config del host (si no, enlaza zstd/openssl del PC). bionic lleva pthread en libc:
# se crea un libpthread.a vacío para satisfacer -lpthread.
mkdir -p "$WORK/stub" && "$AR" rcs "$WORK/stub/libpthread.a"
PKG_CONFIG_LIBDIR="$WORK/stub" PKG_CONFIG_PATH="" \
./configure -q --host="$TRIPLE" \
  --disable-fuse --disable-lzma --without-uuid --without-zlib --without-libzstd \
  --without-libcurl --without-openssl --without-libxml2 --without-json-c \
  ac_cv_func_copy_file_range=no \
  liblz4_CFLAGS="-I$WORK/lz4/lib" liblz4_LIBS="-llz4" \
  LDFLAGS="-L$WORK/stub -L$WORK/lz4/lib" CFLAGS="-O2"
grep -q "define LZ4_ENABLED 1" config.h || { echo "ERROR: erofs-utils sin soporte LZ4" >&2; exit 1; }
make -s -j"$(nproc)"

for t in mkfs/mkfs.erofs fsck/fsck.erofs dump/dump.erofs; do
  name="$(basename "$t")"
  "$STRIP" "$t"
  cp "$t" "$OUT/lib${name//./_}.so"
  echo "  -> $OUT/lib${name//./_}.so ($(du -h "$t" | cut -f1))"
done
