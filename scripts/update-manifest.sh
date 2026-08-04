#!/usr/bin/env bash
# ============================================================
# update-manifest.sh — 扫描 so/ 目录，更新 manifest.json
# 用法: ./scripts/update-manifest.sh
# ============================================================
set -euo pipefail

MANIFEST="manifest.json"
SO_DIR="so"

if [ ! -f "$MANIFEST" ]; then
  echo "❌ 找不到 $MANIFEST，请在项目根目录运行此脚本"
  exit 1
fi

if [ ! -d "$SO_DIR" ]; then
  echo "❌ 找不到 $SO_DIR 目录"
  exit 1
fi

# 收集 .so 文件
SO_FILES=()
while IFS=  read -r f; do
  SO_FILES+=("$f")
done < <(find "$SO_DIR" -maxdepth 1 -name '*.so' -type f | sort)

if [ ${#SO_FILES[@]} -eq 0 ]; then
  echo "⚠️  $SO_DIR/ 目录下没有 .so 文件"
fi

echo "📦 找到 ${#SO_FILES[@]} 个 .so 文件"
echo ""

# 读取现有 manifest 保留设备名称和内核信息
declare -A EXISTING_NAMES
declare -A EXISTING_KERNELS
if command -v python3 &>/dev/null; then
  while IFS='|' read -r so_path name kernel; do
    EXISTING_NAMES["$so_path"]="$name"
    EXISTING_KERNELS["$so_path"]="$kernel"
  done < <(python3 -c "
import json,sys
try:
    with open('$MANIFEST') as f:
        m = json.load(f)
    for d in m.get('devices', []):
        so = d.get('so','')
        name = d.get('name','')
        kernel = d.get('kernel','')
        if so and name:
            print(f\"{so}|{name}|{kernel}\")
except: pass
" 2>/dev/null || true)
fi

# 生成 JSON
echo "{"
echo '  "version": 2,'
echo '  "note": "自动生成 — 运行 scripts/update-manifest.sh 可刷新此文件",'
echo '  "devices": ['

FIRST=true
for SO_PATH in "${SO_FILES[@]}"; do
  SO_FILE=$(basename "$SO_PATH")
  SO_REL="so/$SO_FILE"
  
  # 保留已有的名称信息或使用文件名
  NAME="${EXISTING_NAMES[$SO_REL]:-${SO_FILE%.so}}"
  KERNEL="${EXISTING_KERNELS[$SO_REL]:-}"
  
  if [ "$FIRST" = false ]; then echo ","; fi
  FIRST=false
  
  echo -n "    { \"name\": \"$NAME\", \"kernel\": \"$KERNEL\", \"so\": \"$SO_REL\" }"
done

echo ""
echo "  ]"
echo "}"
echo ""
echo "✅ manifest.json 已更新 (${#SO_FILES[@]} 个设备)"
