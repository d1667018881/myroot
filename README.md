# myroot — 自用 Android 一键 Root 工具页

基于 NebuSec IonStack（CVE-2026-10702 + CVE-2026-43499）的自用部署版本。

## 目录结构

```
├── index.html              ← 主页面（设备选择 + 终端）
├── exploit.js              ← JIT exploit + LD_PRELOAD 提权逻辑
├── ansi.js                 ← ANSI 终端渲染
├── manifest.json           ← .so 文件清单（含 SHA256）
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

**Cloudflare Pages（推荐，免费支持私有仓库）：**

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Workers & Pages → Pages → Create a Page → Connect to Git
3. 授权 GitHub，选择 `d1667018881/myroot`
4. 构建设置：
   - 框架预设: **None**
   - 构建命令: _(留空)_
   - 构建输出目录: **`/`** (或留空)
5. 部署完成会自动分配 `xxx.pages.dev` 域名

**本地测试：**

```bash
python3 -m http.server 8080
# 浏览器访问 http://localhost:8080
```

### 6. 在手机上使用

1. 手机安装 Firefox 151.0 arm64（archive.mozilla.org 可下载旧版）
2. 用 Firefox 打开部署后的网址
3. 选择你的设备型号
4. 点击「校验 .so」— 页面会计算 SHA256 并对比 manifest，防止文件被篡改
5. 校验通过后点击「获取 Root」
6. 终端显示 `uid=0(root)` 即成功

## 安全说明

- 每次使用前页面会验证 .so 的 SHA256 与 manifest 中的哈希是否一致
- 如果 .so 文件被篡改，校验会失败并拒绝执行
- 添加新 .so 后务必运行 `update-manifest.sh` 更新哈希
- **仅供自用，请勿公开分享此页面**

## 免责声明

本工具仅供安全研究和个人设备测试使用。请严格遵守当地法律法规。
只能在你自己拥有的设备上运行。操作前请备份重要数据。
