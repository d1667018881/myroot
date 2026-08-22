# myroot — 自用 Android 临时 Root 网页

基于 Firefox for Android 的 JIT 漏洞（CVE-2026-10702）+ GhostLock（CVE-2026-43499）内核提权。
免安装、纯网页、**重启即恢复**（临时 root，不修改系统分区、不留残留）。

> 线上地址：https://d1667018881.github.io/myroot/

## 方案概览

网页内置两组方案，在"选择设备"弹窗里分组显示：

| 分组 | 漏洞 | 提权方式 | root 管理 | 适用机型 |
|------|------|---------|----------|---------|
| **GhostLock 方案** | CVE-2026-43499 futex PI UAF | W1/W2/W3 三步提权 | KernelSU（App 授权） | 23 个新内核 + 2 个预编译 |
| **IonStack 方案** | NebuSec IonStack | physrw 物理读写 | su daemon（裸 root） | 10 个（hexo141 搬运） |

两组都共用同一入口：Firefox JIT 漏洞拿 shell → 上传 .so 提权，区别只在 .so 的实现。

## 使用前提

1. **Firefox for Android ≤ 151.0**（漏洞在更高版本已修复，151.0.0 是最后一版可用）
2. 设备为 **arm64** 架构
3. **先安装 KernelSU 管理器 App**（GhostLock 方案提权时需从 App 提取 ksud 组件）

> 注意区分：KernelSU 管理器 App（普通 App，提权前先装）≠ KernelSU 内核模块（root 能力，提权后才加载）。
> "装 App" 只是准备好工具，真正拿到 root 靠网页提权，提权后 App 自动激活。

## 使用步骤

1. 安装 Firefox ≤151.0（关掉自动更新）+ KernelSU App
2. 无痕窗口打开网页 → 点「选择设备」→ 选你的机型
3. 点「获取 Root」→ 等终端日志输出
4. 成功后 KernelSU App 从"未安装"变"已越狱"
5. 重启手机即恢复未 root 状态（临时 root，需用时重跑）

**测试要点**（概率性 exploit 的环境要求）：
- Firefox 全程前台（后台 cgroup 会被 LMK 杀进程）
- 重启后立即测（系统最干净，成功率最高）
- 每次测试间隔 5 分钟以上，别连续跑（会触发 watchdog 重启）

## 工作原理

```
① Firefox JIT 漏洞 (CVE-2026-10702)
   仅 Firefox for Android ≤ 151.0 受影响
   → 泄漏 typed array 元数据 → 任意读写 → mprotect shellcode
   → 在 untrusted_app 沙箱内执行 shell 命令（uid 10478）

② 上传 ghostlock.so 到 Firefox 私有目录
   /data/data/org.mozilla.firefox/files/res

③ LD_PRELOAD 触发（SELinux 禁止 untrusted_app execve app data 文件，
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
| 6 | woshi preload（beryl/rodin）默认路径不可写 | 读 `KSUD_DST` 等环境变量，默认 `/data/local/tmp` | `exploit.js` 注入 `KSUD_DST/KSUD_LOG` 到 Firefox 私有目录 |

第 5 条最隐蔽：现象是 W1/W2 都过、日志显示 `child is root!`，但 KernelSU 一直是"未安装+越狱按钮"，且 `.ghostlock_ksu.log` 不存在。根因是 root shell 链继承 LD_PRELOAD 导致递归重跑（日志出现多个 uid=0 的 startup context）。

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
2. `manifest.json` 的 ghostlock 组加一条：
   ```json
   {"name": "机型名 (ghostlock)", "kernel": "uname -r", "so": "so/ghostlock.so?v=6", "spawn": true, "vendor": "厂商", "brand": "品牌"}
   ```
3. Firefox（≤151.0）无痕打开网页 → 选机型 → 获取 Root
4. 看日志 outcome：
   - `ksu` = 完整成功（KernelSU 激活）
   - `root`/`rootNoKsu` = 拿到 root 但 late-load 未确认（看 ksu log）
   - `w1fail`/`collfail`/`killed` = 概率性失败，重启后重试

**内核不在 22 表里** → 用 YuKongA 原仓库的 `extract_rs` 工具（见下方"偏移提取教程"）
生成 offsets.json，放入网页根目录或导入。

## 支持机型清单（共 38 个设备）

### GhostLock 方案（28 个 · CVE-2026-43499 futex → KernelSU）

### 小米集团

**小米**

- Xiaomi 17 / 17 Pro / 17 Pro Max / 17 Ultra  ✅实测 — `6.12.23-android16-5-g75e9b1c7ae7c-abogki463945075-4k`
- Xiaomi 17T (b01b) — `6.6.102-android15-8-gb01b41c2647c-ab15574720-4k`
- Xiaomi 17T (fe76) — `6.6.102-android15-8-gfe76d1bc97fd-ab14689815-4k`
- Xiaomi Civi 5 Pro / K90 / POCO F7 — `6.6.77-android15-8-g4a507830d890-ab13636293-4k`
- Xiaomi 15 — `6.6.77-android15-8-g63ce7556864c-ab13994517-4k`
- Xiaomi 15 Pro / K80 Pro / K80 Ultra — `6.6.77-android15-8-gca30f3b4bef6-abogki440974771-4k`
- 小米 14 (beryl) — `6.6 系列（预编译，机型专用）`
**红米**

- REDMI Note 15 4G / POCO M6 Pro 4G — `6.12.30-android16-5-g6e872b4863d6-ab13847919-4k`
- REDMI K90 Pro Max — `6.12.23-android16-5-g16e473de48a3-abogki462654244-4k`
- REDMI K90 Ultra (608a) — `6.6.118-android15-8-g608a629fedf7-ab15154340-4k`
- REDMI K80 Pro / Turbo 5 Max / POCO X8 Pro Max / Pad 7 Ultra — `6.6.118-android15-8-gc44b714366cc-abogki519650608-4k`
- REDMI K90 Ultra / POCO F7 — `6.6.118-android15-8-ge56cf6b09cca-ab15511674-4k`
- Redmi K70 / K80 Pro (rodin) — `6.6 系列（预编译，机型专用）`
**POCO**

- POCO X8 Pro Max — `6.6.89-android15-8-g0889fe95bb10-ab14402178-4k`
### OPPO 集团

**OPPO**

- OPPO Find X9 / X9 Pro — `6.12.23-android16-5-g82efd98459a2-ab14457512-4k`
- OPPO Find N5 — `6.6.118-android15-8-g2e6b9c3812c5-ab15114928-4k`
- OPPO Find X8 Ultra / OnePlus 13 / ACE 5 Pro — `6.6.118-android15-8-g93e223c276e7-abogki500782043-4k`
- OPPO Pad 5 / OnePlus Pad 2 — `6.6.118-android15-8-ge58033dc8ea6-abogki498046332-4k`
- OPPO Find X8 / X8 Pro — `6.6.118-android15-8-gebdfad32d749-ab15099304-4k`
- OPPO Pad 4 Pro — `6.6.89-android15-8-g096cdb6ecefc-ab14358676-4k`
**一加**

- OnePlus 15T — `6.12.38-android16-5-g844001fb8721-ab14552068-4k`
- OnePlus 15 (a8f88) — `6.12.23-android16-5-ga8f88ad96df3-ab13929693-4k`
- OnePlus 15 (b2a87) — `6.12.23-android16-5-gb2a876903b49-ab14541642-4k`
- OnePlus 13 — `6.6.89-android15-8-gf4dc45704e54-abogki446052083-4k`
### 努比亚/红魔

**红魔**

- Red Magic 11 Pro / Tablet 5 Pro — `6.12.23-android16-5-gf1bdb13583da-ab13761046-4k`
- Red Magic 10 Pro / 11 Air / Tablet 3 Pro — `6.6.92-android15-8-g3637f4904cf5-ab13944661-4k`
- Red Magic Tablet 3 Pro — `6.6.30-android15-8-g54dcbfbef792-ab12368803-4k`

### IonStack 方案（10 个 · physrw → su daemon）

### 小米集团

**红米**

- Redmi K80 Ultra (OS2) — `6.6（含 KernelSU，OS2 版本）`
- Redmi K80 Ultra (OS3) — `6.6（含 KernelSU，OS3 版本）`
- Redmi K40 系 (SM8250) — `4.19.157，骁龙870，Android 13`
### OPPO 集团

**OPPO**

- OPPO Find X8 — `ColorOS 16（6.6，原仓库未标注完整 uname）`
- OPPO PCKM00 (OP4A57) — `4.14.180，骁龙6150，Android 11`
**realme**

- Realme RMX5200 — `未标注（原仓库未提供内核版本）`
### vivo 集团

**iQOO**

- iQOO Neo11 Plus (PD2520) — `GKI 6.6，骁龙8 Elite，Android 16`
- iQOO Neo11 — `未标注（原仓库未提供内核版本）`
### 其他

**作业帮**

- 作业帮学习机 T20Pro+ — `5.2.0`
**通用**

- 通用核心 (arm) — `纯 exploit，无 su`

完整内核名见 `manifest.json`（`kernel` 字段）。

## 各 .so 来源对照

| 分组 | .so | 原仓库 | 方案 |
|------|-----|--------|------|
| GhostLock 组 | `so/ghostlock.so`（22 内核通用） | [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) | CVE-2026-43499 futex → KernelSU |
| GhostLock 组 | `so/woshi_beryl.so`（小米14） | [woshimaniubi8/CVE-2026-43499-root-KernelSU](https://github.com/woshimaniubi8/CVE-2026-43499-root-KernelSU) | 同漏洞预编译，内置 KernelSU |
| GhostLock 组 | `so/woshi_rodin.so`（K70） | 同上 | 同上 |
| IonStack 组 | `so/iqoo_neo11.so` 等 10 个 | [hexo141/Rootme](https://github.com/hexo141/Rootme)（搬运 [NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia)） | IonStack physrw → su daemon |

> 本仓库不重复造轮子：GhostLock 组用 YuKongA 源码编译（仅加 constructor 入口 + 上述 6 个修复），
> IonStack 组直接搬运 hexo141 的预编译 .so（反编译验证过无恶意）。

## 新增国产机型 .so 抓取指南（重要！新会话必读）

> 本仓库的 .so 全部来自下方开源仓库。**新增机型时按此 SOP 操作**，
> 不依赖历史记忆，所有信息都在这里。

### 来源仓库（抓 .so 的地方）

| 来源 | 内容 | 获取方式 |
|------|------|---------|
| [hexo141/Rootme](https://github.com/hexo141/Rootme) | IonStack 方案 .so（iqoo/oppo/realme/k40 等） | 仓库内直接下载（`so/` 或 releases） |
| [woshimaniubi8/CVE-2026-43499-root-KernelSU](https://github.com/woshimaniubi8/CVE-2026-43499-root-KernelSU) | beryl/rodin preload.so（4.6MB，内置 KernelSU） | 仓库下载 |
| [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) | ghostlock 源码（编译 .so） | 源码编译（见上文"ghostlock.so 编译"） |
| [NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia) | 原版 IonStack 全套源码（含 CVE-2026-43074/64560 等新漏洞） | 源码（需适配） |
| 酷安（羊了个羊、墨夜my 等） | AxManager 插件、KGSL/IMQS 漏洞工具（如 K60 临时 root） | 人工获取后入库 |

### 抓取 + 入库 SOP

```
1. 从来源仓库下载目标机型的 .so
   GitHub API: GET /repos/{owner}/{repo}/contents/{path}
   注意 >1MB 的文件用 git blobs API（contents API 会截断）

2. 安全检查（必做，防恶意代码）——见下方"反编译验证清单"

3. 放入 myroot/so/ 目录

4. manifest.json 添加设备条目（照抄现有条目格式）：
   {
     "name": "机型名",
     "kernel": "完整 uname -r（或描述）",
     "so": "so/文件名",
     "spawn": true,          // ghostlock 方案必填 true
     "source": "原仓库名",
     "sourceUrl": "https://github.com/...",
     "vendor": "xiaomi/oppo/vivo/nubia/other",   // 排序用
     "brand": "小米/红米/OPPO/一加/realme/iQOO/红魔"  // 排序用
   }

5. 分组规则：
   - GhostLock 组（futex PI UAF → KernelSU）：spawn:true
   - IonStack 组（physrw → su daemon）：spawn 缺省

6. 上传 GitHub（push 到 main，触发 Pages 自动更新）
7. 验证：Firefox ≤151.0 无痕打开网页 → 选机型 → 获取 Root
```

### 反编译验证清单（安全检查，每次必做）

```bash
# 1. 确认架构（应为 ARM64）
file xxx.so
# 期望: ELF 64-bit LSB pie executable, ARM aarch64

# 2. 恶意特征字符串扫描（网络外传/危险行为）
strings -n 6 xxx.so | grep -iE "socket|connect|http://|https://|curl|wget|mkfifo|rm -rf|/data/|/sdcard/"

# 3. 导入函数检查（异常网络/进程行为）
llvm-readelf -sW xxx.so | grep UND | grep -iE "socket|connect|send|recv|execve|system"
# 干净的 exploit 只应有: open/ioctl/mmap/memcpy/futex 等系统调用

# 4. 与声明漏洞对比（ghostlock 应有 futex/pselect/kernelsnitch 特征）
strings -n 8 xxx.so | grep -iE "futex|pselect|kernelsnitch|GHOSTLOCK_HOME"

# 5. 检查 constructor 入口（LD_PRELOAD 触发用）
llvm-readelf -x .init_array xxx.so   # 应有指向用户 constructor 的指针
```

### 机型匹配规则（重要）

- **每个 .so 是内核/机型特定的**，不能跨机型通用（偏移和地址写死）
- 新增机型先确认内核 `uname -r`：
  - 在 ghostlock 25 内核表 → 直接用 `so/ghostlock.so`
  - 不在表里 → 需要 offsets.json（见"偏移提取教程"）或找该机型的专用 .so
- **老内核（5.x/6.1）无 BTF** → extract_rs 算不出结构体偏移，ghostlock 不可用；
  可考虑 NebuSec 新漏洞（CVE-2026-43074 eventpoll / CVE-2026-64560 timer，untrusted_app 可达）
  或 KGSL/IMQS 类方案（需要 shell 权限）

### 已确认的漏洞利用事实（供参考，避免重复调研）

- CVE-2026-43074（eventpoll UAF）：**Android GKI 5.10 未修复**（ep_free 直接 kfree），
  **但 NebuSec 的 exploit 硬性要求 uid=2000 + u:r:shell:s0**（shell→root 设计），untrusted_app 不可用
- CVE-2026-64560（timer race）：**Android GKI 5.10 未修复**（无内存屏障），
  **同样硬性要求 shell 权限**（shell_security_gate 检查 uid=2000 + shell 域）
- CVE-2026-43499（futex）：影响所有内核，但 exploit 需 BTF 算偏移，老内核无 BTF 卡死
- KGSL/IMQS（AxManager 方案）：老内核可用，但入口需要 shell 权限（untrusted_app 够不着）
- **核心结论：K60（5.10）的 untrusted_app 层级没有任何可用 exploit**
  （futex 无 BTF / eventpoll+timer 要 shell / KGSL+IMQS 入口关闭）
  → 网页方案只适用于"untrusted_app 可达且 exploit 不依赖 shell 环境"的漏洞
- shell 权限（adb/AxManager/Shizuku）下可用的 K60 方案：
  ① AxManager 插件（KGSL+IMQS，已验证）② 未来适配 43074/64560（更干净，工程量大）

## 偏移提取教程（直接用原仓库方法）

**特殊场景：GKI 老内核（5.10 无 BTF）怎么拿偏移**（如 K60）：

```
⚠️ 结论（2026-08 已实测确认）：CVE-2026-43499 ghostlock 的 W1 原语与 5.10 栈布局不兼容——
   pselect fd_set 与 futex waiter 栈相对 delta=-32（6.x 要求 delta>=0），
   偏移全对也会 panic 重启（实测两次）。5.10 设备勿走 ghostlock 网页方案。
   推导依据：反汇编 K60 boot.img 五个函数（__arm64_sys_pselect6/core_sys_select/
   __arm64_sys_futex/do_futex/futex_wait_requeue_pi）+ kallsyms 恢复（142761 符号）+
   设备 BTF（164773 类型）三重验证，偏移本身全对，死因是 W1 攻击原语。

偏移获取方法（供研究/其他利用链参考）:
1. 确认内核是 GKI（uname 含 -gki- 或 android12-5.10 命名；K60 实测 =
   5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284）
2. 找对应 GKI 分支的带 BTF vmlinux:
   a. ci.android.com: builds/branches/aosp_kernel-common-android12-5.10/status.json
      拿 kernel_aarch64 的 last_known_good_build id，再找 artifact 下载（页面 view 里找链接）
   b. Pixel 6（oriole，android12-5.10 设备）factory image 的 boot.img → 提取 vmlinux（带 BTF）
   c. android12-5.10 源码 + gki_defconfig 编译（慢但可靠）
3. 用 extract_rs 处理带 BTF 的 vmlinux（boot.img）→ 生成完整 offsets.json
   （或 pahole -C task_struct vmlinux 直接看字段偏移）
4. ⚠️ 设备 boot.img 无 BTF 时，extract_rs 会跳过 pselect 布局推导（需 BTF），
   启发式 pselect_waiter_shift 不可信——布局可行性必须用 BTF 补齐推导验证，
   不能只看偏移表能不能生成。

✅ K60 研究过程记录（2026-08）:
   - 设备自带 BTF（root 提取 /sys/kernel/btf/vmlinux，164773 类型）解析确认:
     task_struct 关键偏移（prio/pi_lock/pi_waiters/pi_top_task/pi_blocked_on/
     pid/tgid/atomic_flags/real_cred/cred/comm/tasks/seccomp）与 6.12 **完全一致**
   - rt_mutex_waiter（tree=0x0/pi_tree=0x28/task=0x50）、cred（uid=0x8/
     security=0x80）、struct page（0x40/0x8/0x30）均与 target.h 默认一致
   - 符号偏移（init_task/init_cred/selinux_*/slide_*）由卡刷包 payload 的
     kallsyms 恢复（extract_rs，142761 符号），AxManager 写死地址交叉验证吻合
   - 适配项: kernel_phys_load=0x80000000（高通 GKI）、
     kimage_text_base=0xffffffc008000000
   - 最终判定: W1 原语不兼容 5.10（delta=-32），条目已下架
```

新机型内核不在内置 25 表里时，用 YuKongA 原仓库的 `tools/extract_rs` 提取偏移：

```bash
# 方式 1：本地 boot.img
cargo build --release --manifest-path tools/extract_rs/Cargo.toml
tools/extract_rs/target/release/ghostlock-extract boot.img \
  --xbl-config xbl_config.img --format json --out offsets.json

# 方式 2：OTA 卡刷包（本地 zip 或 URL）
ghostlock-extract OTA.zip --format json --out offsets.json
ghostlock-extract https://host/full-ota.zip --format json --out offsets.json

# 方式 3：生成 C 头文件（注册进 src/kernels/<uname>/offsets.h）
ghostlock-extract boot.img --xbl-config xbl_config.img --register
```

详细说明见原仓库 README（kallsyms 恢复、MTK 无 xbl_config 的处理、`--phys` 覆盖物理加载地址等）：
https://github.com/YuKongA/ghostlock-app#offset-extraction

**网页端接入**：把 `offsets.json` 放到网页根目录（或导入），ghostlock 运行时会在
`$GHOSTLOCK_HOME/offsets.json` 查找外部偏移（内置表优先，外部表补缺）。

## 上游项目

本项目的核心组件均来自以下开源项目，特此致谢：

- [YuKongA/ghostlock-app](https://github.com/YuKongA/ghostlock-app) — GhostLock 源码（CVE-2026-43499，22 内核偏移表）
- [woshimaniubi8/CVE-2026-43499-root-KernelSU](https://github.com/woshimaniubi8/CVE-2026-43499-root-KernelSU) — beryl/rodin 预编译 preload.so（内置 KernelSU）
- [NebuSec/CyberMeowfia](https://github.com/NebuSec/CyberMeowfia) — IonStack 全套源码（Firefox JIT + 内核 exploit 原版）
- [hexo141/Rootme](https://github.com/hexo141/Rootme) — IonStack 方案的 .so 搬运来源
