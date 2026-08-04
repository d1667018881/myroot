# myroot — 自用 Android 一键 Root 工具页

基于 NebuSec IonStack（CVE-2026-10702 + CVE-2026-43499）的自用部署版本。

## 目录结构

```
├── index.html              ← 主页面（设备选择 + 终端）
├── exploit.js              ← JIT exploit + LD_PRELOAD 提权逻辑
├── ansi.js                 ← ANSI 终端渲染
├── manifest.json           ← .so 文件清单
├── Assets/
│   ├── modal.css
│   └── modal.js
├── so/                     ← 把你的 .so 文件放这里
│   └── example.so
└── scripts/
    └── update-manifest.sh  ← 添加 .so 后运行此脚本刷新清单
```

## 使用方法

### 1. 首次搭建

```bash
git clone git@github.com:d1667018881/myroot.git
cd myroot
```

### 2. 添加你的 .so 文件

把你编译好的设备专属 .so 放到 `so/` 目录：

```bash
cp /path/to/your_device.so so/
```

### 3. 更新清单

```bash
chmod +x scripts/update-manifest.sh
./scripts/update-manifest.sh
```

脚本会自动扫描 `so/` 目录，计算每个 .so 的 SHA256，写入 `manifest.json`。

如果想修改设备显示名称或内核版本信息，直接编辑 `manifest.json` 对应字段。

### 4. 提交并推送

```bash
git add .
git commit -m "添加 xxx 设备支持"
git push
```

### 5. 部署

**GitHub Pages（已配置）：**

仓库已启用 GitHub Pages，推送后自动部署。
访问地址：https://d1667018881.github.io/myroot/

**本地测试：**

```bash
python3 -m http.server 8080
# 浏览器访问 http://localhost:8080
```

### 6. 在手机上使用

1. 手机安装 Firefox 151.0 arm64（archive.mozilla.org 可下载旧版）
2. 用 Firefox 打开部署后的网址
3. 选择你的设备型号，点击「获取 Root」
4. 或点击「本地上传 .so」选择手机里的 .so 文件，再点「使用本地 .so 执行」
5. 终端显示 `uid=0(root)` 即成功

## 安全说明

- 仓库为公开仓库，仅自己有写入权限
- 支持本地上传 .so 文件，不依赖网络下载
- **仅供自用，请勿用于他人设备**

## 免责声明

本工具仅供安全研究和个人设备测试使用。请严格遵守当地法律法规。
只能在你自己拥有的设备上运行。操作前请备份重要数据。
