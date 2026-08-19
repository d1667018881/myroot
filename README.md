# myroot — 自用 Android 临时 Root 网页

基于 Firefox for Android 的 JIT 漏洞 + GhostLock（CVE-2026-43499）内核提权。
免安装、纯网页、重启即恢复（临时 root，非永久）。

> 线上：https://d1667018881.github.io/myroot/

## 工作原理

```
① Firefox JIT 漏洞 (CVE-2026-10702)
   仅 Firefox for Android ≤ 151.0 受影响（151.0.0 是最后一版可用）
   → 泄漏 typed array 元数据 → 任意读写 → mprotect shellcode
   → 在 untrusted_app 沙箱内执行 shell 命令（uid 10478）

② 上传 ghostlock.so 到 Firefox 私有目录
   /data/data/org.mozilla.firefox/files/res

③ LD_PRELOAD 触发（关键：SELinux 禁止 untrusted_app execve app data 文件，
   但允许 dlopen / LD_PRELOAD）
   ghostlock.so 带 constructor 入口，加载即自动执行

④ GhostLock 提权链
   W1: 打穿 SELinux → permissive
   W2: 改 child cred → root（uid=0）
   W3: 绕过 seccomp（root 流程下 Seccomp=0 会自动跳过）
   → root shell 执行 .ghostlock_root.sh → ksud late-load 加载 kernelsu.ko
   → KernelSU 激活（App 直接显示已越狱，无按钮）
```

## 关键修复记录（务必保留，勿回退）

这些坑已全部固化进代码，任何一个回退都会复现失败：

| # | 坑 | 根因 | 修复 |
|---|-----|------|------|
| 1 | ghostlock 工作目录 `/data/local/tmp` 不可写 | untrusted_app 无权限 | spawn 时注入 `GHOSTLOCK_HOME/TMPDIR/HOME` 到 Firefox 私有目录 |
| 2 | execve Permission denied | SELinux 禁止 untrusted_app exec app data | 编译成共享库走 LD_PRELOAD + constructor |
| 3 | W1 写入无效（route success 但 SELinux 不变） | 写入源 `*(base+0x100)` 内容环境相关（0 或 0x41） | `util.c` 把 skb 偏移 0xf80 显式写 0 |
| 4 | ghostlock 进程被 LMK 杀 | fork ~400 子进程触发后台 cgroup 回收 | MM_PARTIALS 5→2、prepare 8x→5x、fork 每 8 个 usleep、碰撞前提前清理 |
| 5 | **KernelSU 永远不激活（.ghostlock_ksu.log 不存在）** | root shell exec 时继承 `LD_PRELOAD` → constructor 在 root 上下文无限重跑，root script 永不执行 | `main.c` exec root script 前 `unsetenv("LD_PRELOAD")` |

第 5 条是最隐蔽的：现象是 W1/W2 都过、日志显示 `child is root!`，但 KernelSU 一直是"未安装+越狱按钮"，且 `.ghostlock_ksu.log` 不存在。根因是 root shell 链继承 LD_PRELOAD 导致递归重跑（日志会出现多个 uid=0 的 startup context）。

## ghostlock.so 编译

```bash
NDK=<ndk 路径>
CC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang

$CC -shared -fPIC -O2 -flto \
  -Wall -Wno-unused-parameter -Wno-sign-compare -Wno-unused-function \
  -Isrc/core -Isrc/kernels \
  -DTARGET_CONFIG_H=\"target.h\" \
  src/core/main.c src/core/offsets_json.c src/core/util.c src/core/fops.c \
  -o ghostlock.so -pthread
```

**必须验证 constructor 在**（LD_PRELOAD 触发的唯一入口）：

```bash
llvm-readelf -x .init_array ghostlock.so
# 应有 3 个指针，其中一个指向 ghostlock_preload_init
llvm-readelf -sW ghostlock.so | grep ghostlock_preload_init
```

> ⚠️ 直接从 YuKongA/ghostlock-app 克隆编译**没有** constructor（原版是 PIE 可执行文件，
> `main()` 不会被 LD_PRELOAD 触发）。必须用带 constructor 的 main.c（末尾
> `__attribute__((constructor)) ghostlock_preload_init`）。

## 移植新机型 SOP

ghostlock.so **内置 22 个内核偏移表**，运行时按 `uname -r` 自动匹配，通用性极强。

1. 确认目标机型内核在 22 表里（见下方清单，或对比 `uname -r`）
2. `manifest.json` 加一条：
   ```json
   {"name": "机型名 (ghostlock)", "kernel": "uname -r", "so": "so/ghostlock.so?v=6", "spawn": true}
   ```
3. Firefox（≤151.0）无痕打开网页 → 选机型 → 获取 Root
4. 看日志 outcome：
   - `ksu` = 完整成功
   - `root`/`rootNoKsu` = 拿到 root 但 late-load 未确认（看 ksu log）
   - `w1fail`/`collfail`/`killed` = 概率性失败，重启后重试

**内核不在 22 表里** → 用 RootTool APK 的"解析卡刷包"功能生成 offsets.json，
放入网页根目录或导入。

**测试要点**（概率性 exploit 的环境要求）：
- Firefox 全程前台（后台 cgroup 会被 LMK 杀）
- 重启后立即测（系统最干净）
- 每次测试间隔 5 分钟以上，别连续跑（会触发 watchdog 重启）

## 支持机型清单（ghostlock，22 内核）

| 机型 | uname -r |
|------|----------|
| Xiaomi 17 / 17 Pro / 17 Pro Max / 17 Ultra | 6.12.23-...-g75e9b1c7ae7c-... |
| REDMI K90 Pro Max | 6.12.23-...-g16e473de48a3-... |
| OPPO Find X9 / X9 Pro | 6.12.23-...-g82efd98459a2-... |
| OnePlus 15 (×2 内核) | 6.12.23-...-ga8f88ad96df3 / gb2a876903b49 |
| Red Magic 11 Pro / Tablet 5 Pro | 6.12.23-...-gf1bdb13583da-... |
| REDMI Note 15 4G / POCO M6 Pro 4G | 6.12.30-...-g6e872b4863d6-... |
| OnePlus 15T | 6.12.38-...-g844001fb8721-... |
| Xiaomi 17T (×2 内核) | 6.6.102-...-gb01b41c2647c / gfe76d1bc97fd |
| OPPO Find N5 | 6.6.118-...-g2e6b9c3812c5-... |
| REDMI K90 Ultra (×2 内核) | 6.6.118-...-g608a629fedf7 / ge56cf6b09cca |
| OPPO Find X8 Ultra / OnePlus 13 / ACE 5 Pro | 6.6.118-...-g93e223c276e7-... |
| REDMI K80 Pro / Turbo 5 Max / POCO X8 Pro Max / Pad 7 Ultra | 6.6.118-...-gc44b714366cc-... |
| OPPO Pad 5 / OnePlus Pad 2 | 6.6.118-...-ge58033dc8ea6-... |
| OPPO Find X8 / X8 Pro | 6.6.118-...-gebdfad32d749-... |
| Xiaomi Civi 5 Pro / K90 / POCO F7 | 6.6.77-...-g4a507830d890-... |
| Xiaomi 15 | 6.6.77-...-g63ce7556864c-... |
| Xiaomi 15 Pro / K80 Pro / K80 Ultra | 6.6.77-...-gca30f3b4bef6-... |
| OPPO Pad 4 Pro | 6.6.89-...-g096cdb6ecefc-... |
| OnePlus 13 | 6.6.89-...-gf4dc45704e54-... |

完整 22 个内核名见 `manifest.json`（`kernel` 字段）或 `src/kernels/` 目录。

## 相关仓库

- 网页本项目：github.com/d1667018881/myroot
- APK 项目（已成功，正式签名 v6）：github.com/d1667018881/RootTool
- ghostlock 源码来源：github.com/YuKongA/ghostlock-app
- 网页 JIT 漏洞参考：hexo141/Rootme、NebuSec/CyberMeowfia
- preload.so 变体：woshimaniubi8/CVE-2026-43499-root-KernelSU
