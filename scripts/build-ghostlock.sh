#!/bin/bash
# Build ghostlock.so for the web root (all local customizations in one patch)
# Usage: ./scripts/build-ghostlock.sh [--commit]
#
# Patch (scripts/ghostlock-local-0923.patch) is bound to upstream baseline
# 10001ae1 (09-23). On a new upstream sync: re-apply the hunks manually,
# regenerate the patch, and bump ?v= in manifest.json.
#
# Customizations included:
#   1. MM_PARTIALS 5 -> 2, prepare_ctx 8x -> 5x   (LMK: fewer forks)
#   2. usleep(5000) every 8 forks                  (LMK: fork throttle)
#   3. prepare_ctx early cleanup + dedup fail paths
#   4. main.c: ghostlock_preload_init constructor + unsetenv(LD_PRELOAD)
#      (web entry; was injected ad-hoc for the 08-19 build, now tracked)
#   5. util.c: route-conditional task-pointer view (tcp -> direct-map alias,
#      pselect -> kernel image) — fixes the v14 W1 regression on QCOM 6.12
#      (upstream 9e750039 broke non-compact pselect with aliases)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$REPO_DIR/build-ghostlock"
PATCH_FILE="$SCRIPT_DIR/ghostlock-local-0923.patch"
UPSTREAM_REF="10001ae1"
OUTPUT="$REPO_DIR/so/ghostlock.so"

# ONDK setup
ONDK_VERSION="${ONDK_VERSION:-r30.1}"
ONDK_HOME="${ONDK_HOME:-${HOME}/ondk-${ONDK_VERSION}}"
API="${API:-35}"

echo "=== Building ghostlock.so (local customizations) ==="
echo "ONDK_HOME=$ONDK_HOME"
echo "API=$API"

# Clone ghostlock-app if not already done
if [ ! -d "$WORK_DIR" ]; then
  echo "Cloning ghostlock-app..."
  git clone https://github.com/YuKongA/ghostlock-app.git "$WORK_DIR"
fi

cd "$WORK_DIR"
git checkout -- .
git checkout main
git fetch origin main 2>/dev/null || true
# pin to the baseline the patch is bound to
git checkout -q "$UPSTREAM_REF" 2>/dev/null || git pull --ff-only origin main 2>/dev/null || true

# Apply local patch
echo "Applying local patch..."
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
CUR=$(grep -o 'so/ghostlock.so?v=[0-9]*' "$MANIFEST" | head -1 | rg -o '[0-9]+')
NEW=$((CUR + 1))
echo "Updating manifest ?v=$CUR -> v=$NEW..."
sed -i "s|so/ghostlock.so?v=[0-9]*|so/ghostlock.so?v=$NEW|g" "$MANIFEST"

# Commit if requested
if [ "${1:-}" = "--commit" ]; then
  cd "$REPO_DIR"
  git add so/ghostlock.so manifest.json scripts/
  git commit -m "ghostlock.so: rebuild from upstream 10001ae1 + local patch [skip ci]" || true
  echo "Committed. Push with: git push origin main"
fi

echo "Done!"