#!/bin/bash
# Build ghostlock.so for Xiaomi 17 (LMK fix)
# Usage: ./scripts/build-ghostlock.sh [--commit]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$REPO_DIR/build-ghostlock"
PATCH_FILE="$SCRIPT_DIR/ghostlock-lmk-fix.patch"
OUTPUT="$REPO_DIR/so/ghostlock.so"

# ONDK setup
ONDK_VERSION="${ONDK_VERSION:-r30.1}"
ONDK_HOME="${ONDK_HOME:-${HOME}/ondk-${ONDK_VERSION}}"
API="${API:-35}"

echo "=== Building ghostlock.so (LMK fix) ==="
echo "ONDK_HOME=$ONDK_HOME"
echo "API=$API"

# Clone ghostlock-app if not already done
if [ ! -d "$WORK_DIR" ]; then
  echo "Cloning ghostlock-app..."
  git clone --depth 1 https://github.com/YuKongA/ghostlock-app.git "$WORK_DIR"
fi

cd "$WORK_DIR"
git checkout -- .
git checkout main
git pull --ff-only origin main 2>/dev/null || true

# Apply LMK fix patch
echo "Applying LMK fix patch..."
git apply --verbose "$PATCH_FILE"

# Find NDK clang
if [ -n "${ONDK_HOME:-}" ] && [ -d "$ONDK_HOME" ]; then
  NDK_CC="$ONDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
elif [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
  NDK_CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
elif [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
  NDK_CC="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${API}-clang"
else
  echo "ERROR: No NDK found. Set ONDK_HOME, ANDROID_NDK_HOME, or ANDROID_NDK_ROOT"
  exit 1
fi

if [ ! -x "$NDK_CC" ]; then
  echo "ERROR: NDK compiler not found at $NDK_CC"
  exit 1
fi

echo "Compiler: $NDK_CC"

# Build ghostlock.so (shared library with constructor for LD_PRELOAD)
SRCS="src/core/main.c src/core/offsets_json.c src/core/util.c src/core/fops.c"
CFLAGS="-O2 -flto -Wall -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function \
  -Isrc/core -Isrc/kernels -DTARGET_CONFIG_H=\"target.h\""
LDFLAGS="-shared -fPIC -flto -pthread -Wl,-init,_init -Wl,-fini,_fini"

echo "Compiling..."
$NDK_CC $CFLAGS $LDFLAGS $SRCS -o ghostlock.so

# Copy to myroot so/
mkdir -p "$(dirname "$OUTPUT")"
cp ghostlock.so "$OUTPUT"

echo "=== Build complete: $OUTPUT ==="
ls -la "$OUTPUT"
file "$OUTPUT"

# Update manifest version if needed
MANIFEST="$REPO_DIR/manifest.json"
if grep -q '"so/ghostlock.so?v=4"' "$MANIFEST"; then
  echo "Manifest already at v=4"
else
  echo "Updating manifest to v=4..."
  sed -i 's|so/ghostlock.so?v=[0-9]*|so/ghostlock.so?v=4|g' "$MANIFEST"
fi

# Commit if requested
if [ "${1:-}" = "--commit" ]; then
  cd "$REPO_DIR"
  git add so/ghostlock.so manifest.json
  git commit -m "ghostlock.so: LMK fix - reduce spray, early cleanup, fork delays [skip ci]" || true
  echo "Committed. Push with: git push origin main"
fi

echo "Done!"