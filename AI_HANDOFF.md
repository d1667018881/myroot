# AI 交接文档 — myroot（网页版临时 Root）

> 面向接手的 AI / 开发者的**技术交接**。
> 同一项目的 **APK 版**（私有仓库 `RootTool`）有对应文档：`RootTool/AI_HANDOFF.md`，两份内容互补、互相引用。
> 最后更新：~~2026-09-25~~ ~~2026-10-10（v21 双 so 钉死 + 上游换代核查 + 基线全面刷新）~~ 2026-10-16（v22：9 张新表翻译吸收，59 表/74 设备，翻译管线工具化见 §5.5）

---

## 0. 项目是什么

- **目标**：给 arm64 安卓设备提供**临时 root**（重启即恢复，不改系统分区、不留残留）。
- **两层漏洞**：
  - 前置（拿 shell）：**CVE-2026-10702** — Firefox for Android ≤ 151.0 的 JIT 类型混淆
  - 内核提权：**CVE-2026-43499**（GhostLock，futex PI UAF）
- **线上地址**：https://d1667018881.github.io/myroot/ （GitHub Pages）
- **同源产品**：APK `RootTool`（同一套内核提权代码，换成 App 外壳）

---

## 1. 本仓库文件

| 文件 | 作用 |
|---|---|
| `index.html` / `ansi.js` | 页面与终端 UI |
| `exploit.js` | Firefox JIT 漏洞链（stage 1–9）+ 上传 so + LD_PRELOAD spawn + 轮询取日志 |
| `manifest.json` | 设备表（分组 GhostLock / IonStack）；每项含 `kernel` / `so` 引用 / `spawn` / `vendor` 等 |
| `so/ghostlock.so` | 核心提权 so（v21，编译产物，见 §5） |
| `kernels-local/` | 翻译管线产物：上游 HOCON 表→C offsets.h（9 张，见 §5.5）|
| `tools-local/translate_kernels.py` | HOCON→C 表翻译器（字段映射内置家族默认）|
| `so/ghostlock-v19.so` | **小米 17 专用钉死文件**（v19 原字节 80632B，与 2026-09-26 五轮对照实验全链成功的 so 逐字节 cmp 相同，git b68828c）——**实测凭据载体，永远不许改动/重建/覆盖** |

---

## 2. 引用了谁（上游/来源）

| 来源 | 用途 |
|---|---|
| `YuKongA/ghostlock-app` | **核心**：`src/core/*.c` + `src/kernels/*`（偏移表）→ 编译成 `ghostlock.so`。**⚠️ 2026-09-28 核查：上游 main 已架构换代（native C 全量重写为 C++23、48 张 C 表全删换成 HOCON profile）——main 不再可直接取用，构建必须 pin 到冻结 ref（见 §5）** |
| `hexo141/Rootme`（搬运 `NebuSec/CyberMeowfia`） | manifest 的 **IonStack 组** 10 个 .so |
| `woshimaniubi8/CVE-2026-43499-root-KernelSU` | 预编译 so（小米14 beryl / K70 rodin） |

---

## 3. 运行链（网页版专属，重要）

```
① Firefox JIT 漏洞 (CVE-2026-10702)
   → 在 untrusted_app 沙箱内执行 shell (uid 10478)
② 上传 ghostlock.so 到 /data/data/org.mozilla.firefox/files/res
③ LD_PRELOAD 加载 so（SELinux 禁止 untrusted_app execve app_data，
   但允许 dlopen / LD_PRELOAD）→ so 的 constructor 自动执行
④ GhostLock 提权链：W1 破 SELinux → W2 改 cred(→root) → W3 绕 seccomp
   → root shell → ksud late-load → KernelSU 激活
```

关键点（易踩坑）：

- 网页 so 是 **PIE 可执行文件**（不是 `-shared` 库），靠 `__attribute__((constructor))` 在加载时执行。
- `manifest.json` 中 `"spawn": true` 的设备走 **LD_PRELOAD spawn** 模式。
- 页面在等待期会**静默轮询 `ghostlock.log` 最长 120 秒**（UI 故意不输出），之后才打印结果——**不是卡死，别误判**。

---

## 4. 当前状态（基线，2026-10-16 v22 刷新）

| 项 | 值 |
|---|---|
| `so/ghostlock.so`（主） | **83272 字节** = **v22**（09-16 core 冻结 + 09-25 的 50 表 + kernels-local 翻译 9 张新表 = **59 表**；线上 cmp 逐字节验证毕 2026-10-16）|
| `so/ghostlock-v19.so`（钉死） | **80632 字节** = v19 原字节（09-26 真机五轮实验全链成功配方，专供小米 17，**永不改动**）|
| `manifest.json` | version **22**：GhostLock 组 **64 台**——小米 17（唯一实测凭据设备）→ `so/ghostlock-v19.so?v=19`，其余 **63 台** → `so/ghostlock.so?v=22`；IonStack 组 **10 台**走各自独立 so。**共 74 设备**（实测清点）|
| core 冻结基线 | 上游 `1145ef2d`（2026-09-16 core）+ `3bd95d3`（2026-09-25 kernels/表，50 张）+ **`kernels-local/` 9 张翻译表**（HOCON→C，10-16 翻译管线见 §5.5）——build-ghostlock.sh 内 pin（CORE_REF/KERNELS_REF 变量）|
| 上游状态 | **main 已换代**（09-28 核查：C++23 重写 + HOCON 表）；10-16 复查：换代后 47 提交零 panic/revert 信号，表池 64→73 HOCON，已翻译吸收其中 9 张（5.15 家族 6 张不翻=C++ core 专属路线）|
| ~~v21 基线（10-16 前留档）~~ | ~~so 81304B / manifest v21 / 65 设备（GhostLock 55 + IonStack 10）~~ → v22 起被 59 表/74 设备取代 |
| ~~v14 基线（已过时留档）~~ | ~~so 81208B / manifest v14 / 62 设备（09-25）~~ → 已被 v19/v21 双 so 架构取代 |

---

## 5. 构建 so（可复现）

> **⚠️ 上游换代警告（2026-09-28 核查）**：上游 main 的 `src/kernels/*/offsets.h` 已**全部删除**（换 HOCON profile），`src/core` 已重写为 C++23。**照老流程拉 main tarball 必然构建失败/产出行为不可知的二进制**。构建必须 pin 到冻结 ref。
> ~~原流程：curl main.tar.gz → 覆盖编译区 → 重打定制~~（已失效，仅留档）

```bash
# 推荐路径：直接用仓库内已 pin 的脚本
#   CORE_REF=1145ef2d（09-16 core）/ KERNELS_REF=3bd95d3（09-25 kernels，50 表）
bash scripts/build-ghostlock.sh          # clone 上游 → checkout 冻结 ref → apply patch → 编译 → strip

# 手动等价流程（理解用）：
# 1) clone 上游后 checkout 冻结 ref（不许用 main！）
#    git clone https://github.com/YuKongA/ghostlock-app /tmp/upstream-gl
#    git -C /tmp/upstream-gl checkout 3bd95d3          # 09-25：50 张 kernels 表
#    git -C /tmp/upstream-gl checkout 1145ef2d -- src/core   # core 回退到 09-16 冻结基线
#    （v19 复刻用 kernels 09-23 基线 = 10001ae，48 表；v21 用 09-25 = 3bd95d3，50 表）
# 2) 覆盖到编译区
# 3) 重打 §6 的三处定制（common.h / util.c / main.c）——或直接 apply scripts/ghostlock-local-0923.patch
# 4) 编译（NDK r29，产出 PIE 可执行文件） make   # SRCS = src/core/{main.c,offsets_json.c,util.c,fops.c}
# 5) llvm-strip 去符号
# 6) 部署到 so/ghostlock.so 并递增 manifest ?v=——**注意：产物只覆盖主 so，so/ghostlock-v19.so 是实测凭据钉死文件，任何构建流程都不得触碰它**
```

> 部署用 GitHub contents API（二进制走 base64）；**so 与 manifest 分两次提交**（合并易超时）。改了 so 必须递增 `?v=`，否则浏览器/CDN 用旧缓存。

### 5.5 新表翻译管线（上游 09-28 换代后的取表通道，2026-10-16 建立）

上游 C 表已死（换 HOCON），"取表"= 翻译。**全流程工具化**，勿手搓：

```bash
# ① 导出上游新 HOCON 表（先 git fetch && 对比 3bd95d3 的表差量，5.15 家族跳过）
git -C /tmp/upstream-gl show origin/main:app/src/main/assets/kernel_profiles/<release>.conf > /tmp/hocon_pool/<release>.conf
# ② 翻译（HOCON→C offsets.h；字段映射已对 3bd95d3 C-core 逐一验证）
python3 tools-local/translate_kernels.py /tmp/hocon_pool kernels-local/
# ③ 构建会自动 merge（scripts/merge_local_kernels.py 把 kernels-local/ 注册进 known_offsets）
bash scripts/build-ghostlock.sh
# ④ manifest 新设备条目：python json 追加（参考 git log 2405f4b 的注入脚本），
#    设备名从上游 docs/kernel_profiles/SUPPORTED_DEVICES.md 提取 release→设备映射
```

映射规则（验证记录）：`release→uname_r`；`kernel_phys_load`（非 null）→ `.kernel_phys_load`（main.c:112 直接生效）；`route.select_stack.waiter_shift`→`.pselect_waiter_shift`（null 时按家族默认显式写：6.1=1 / 6.6=-2 / 6.12=0）；`offset.{init_task 等 9 项}`→`.off_*`；`task_struct.*`（15 项）→`.task_*`（与家族宏默认相同时省略）；`kernelsnitch.mm_struct_sz`≠家族默认才写。**丢弃**：`kernel_phys_offset`（C core 硬编码 P0_PHYS_OFFSET=0x80000000 无表级字段；50 张老表同样不带——行为一致零新增风险）、`empty_zero_page`、`cred.*`（C++ core 专属 cred 伪造参数）、`kernelsnitch.collisions`、`fallback.*`。**语法红线：表文件结尾必须是 `),`（数组元素逗号）不是 `);`——v22 构建时踩过，`);` 会把 known_offsets 数组提前终结产生 11 个级联编译错。**5.15 家族不翻**（C++ core 专属路线，冻结 C core 不支持）。

---

## 6. 本地定制（覆盖上游后**必须重打**）

| 文件 | 改动 | 原因 |
|---|---|---|
| `src/core/common.h` | `#define MM_PARTIALS 5` → **2** | 提高 mm 喷溅命中率 |
| `src/core/util.c` | `prepare_ctx.mm_cnt = 8*…` → **`5 * mm_objs_per_slab`** | 同上 |
| `src/core/main.c` | ① 文件末加 `__attribute__((constructor)) ghostlock_preload_init()`（调 `run_exploit(0,NULL)`）<br>② root script `execl` 前加 `unsetenv("LD_PRELOAD"); unsetenv("LD_LIBRARY_PATH");` | ① 网页 LD_PRELOAD 加载即执行<br>② 防止 exec 出的子进程再触发 constructor 死循环 |

除这三处外，`src/core/*` 应与上游逐字一致。

---

## 7. 已知问题 / 未决

### 7.1 小米 17 网页版双层回归（2026-09-26 锤定 W1 根因，已回滚止血）
- **设备内核**：`6.12.23-android16-5-g75e9b1c7ae7c-abogki463945075-4k`（小米 17 / 17 Pro / Pro Max / Ultra），QCOM、非 compact、`slide=pselect main=pselect`
- **回归时间线**（关键：每层回归的上游窗口不同）：
  | 构建 | 上游基线 | 小米 17 实测 |
  |---|---|---|
  | 08-19 so（62fdf84） | 上游 08-17 + LMK patch | ✅ **全链成功**（唯一验证过的版本） |
  | 09-10 / 09-16 so | #127+#138+#121 | ❌ W1 过、W2 挂（`child uid=10478` 不变） |
  | 09-24 v14 so | 10001ae（含 9e750039） | ❌ **W1 都挂** + 一次 panic（09-26 实测 3 次：2 次 120s 超时卡在 W1 attempt、1 次卡死重启） |

- **W1 回归首版归因（v16 复测后修正：三字段 alias 是**嫌疑**而非实锤根因）**：上游 `9e750039`（09-17，"Add Pixel 9 Pro"）把 `util.c` payload 三个字段 `waiter_task`/`task_group`/`pi_top_task` 从 **image 视图**（`INIT_TASK`=`ffffffc0…`）改成 **direct-map alias 视图**（`SLIDE_INIT_TASK`=`ffffff80…`）。v13→v14 之间它是唯一碰 `src/core` 的提交（逐 commit 核对过文件列表）——这是事实；但"alias 破坏 PI 链"的机制推断（planted task 指针与 image 形式指针身份比较分叉）**未被 v16 复测证实**（image 视图回退后 W1 仍挂），v16 的挂更可能由构建形态差异（-shared）引入。注意 `success=1` 只是 consumer 的 sched_setattr 成功，不是写入验证——这条判读依然成立。
- **W2 回归（根因仍未定，#127 嫌疑已撤）**：09-16 时代归咎 #127 是**错的**——#127 只改 compact 字表（`relink_pc` 那组），小米 17 走非 compact；非 compact 的 W0 payload 布局、W1/W2 调用参数（mode/leaf）、写入字表在 fork(08-17)→09-16 之间**文本上完全没变**。真正的回归窗口是 **fork→09-10 的 949 行大 diff**（TCP route 引入 + "W2/W3 harden" + kernelsnitch 大改 + W2/W3 改三轮 retry 链 + `pselect_child_node`/perf leak 流程调整），具体哪一处杀的 W2 未定位。另一个未排除假说：perf_find_task 泄漏到错误 task（写入落了但 verify 读的 child 不对）。
- **止血→根治（2026-09-26）**：先部署 v15 回滚（08-19 so）止血；同日 TA 否决回滚方案（丢新设备）→ **v16 forward fix**：上游 10001ae 全量源码 + `scripts/ghostlock-local-0923.patch`（LMK 定制 + constructor 入库 + W1 视图修复）本地重建，so=110832B/48 内核表（与 v14 逐串一致），manifest v16 恢复全部 52 设备，`?v=16`。修复内容：`util.c` 三字段改 `tcp ? SLIDE_INIT_TASK : INIT_TASK`（TCP/Tensor 保 alias，pselect/QCOM 恢复 image），新增日志 `payload task view: kernel image|direct-map alias` 可在真机日志确认修复版在跑。
- **v16 附带还清的交接债**：08-19 手动构建注入的 constructor+unsetenv（`ghostlock_preload_init`）从未入库——v14 的 so 里也有此符号但 patch/脚本都没有，属于"能跑但不可复现"。现已入 patch，`build-ghostlock.sh` 同步重写（pin 到 UPSTREAM_REF=10001ae）。
- **W2 残留风险（未解）**：v16 只修 W1。小米 17 在 09-16 基线上还有"W1 过、W2 挂"的遗留回归（窗口=fork→09-10 的 949 行 diff，根因未定位）。v16 若复现此症状（日志走到 `W2: cred` 反复重试但 `child uid` 不变），下一步按 §10 P2 排查。
- **v16 复测结果（09-26 16:31）：W1 仍挂，且发现归因错误**。日志确认 `payload task view: kernel image`（修复在跑）但 W1 pselect 依旧 success=1 不落——**三字段 alias 不是根因**（或不是唯一根因）。随即取证发现**真正的未控制变量：构建形态**——?v=13（W1 过）与 v14（W1 挂）都是 **PIE executable + stripped + NDK r29**（上游 Makefile 流程），而 v16 误用了 build-ghostlock.sh 的 `-shared` 形态（v15 滚出时一度把 08-19 so 的符号误读为 v14 的）。v16 = shared 形态，引入了新变量，"三字段回退"的效果被形态差异掩盖，无法判读。
- **v17 三版对照实验（09-26 部署）→ 18:39 定案**：
  | 条目 | 结果 |
  |---|---|
  | 校准（08-19 原字节，-shared） | ✅ **全链成功**（环境没变，排除环境漂移） |
  | A（PIE + 09-23 core + 三字段回退） | ❌ W1 挂 |
  | D（?v=13 原字节） | ❌ **W1 挂**——9/16 那次"W1 过"不可复现，是 15 次尝试里的运气 |
  | C（**自建 09-16 core 复刻**，PIE） | ✅ **全链成功**（W1 5.7s 一击、W2 retry-2 `child is root`、late-load `exit=0`、**跳转 KernelSU App 显示成功**） |

- **定案**：① 构建形态（PIE/-shared）**不是**变量（08-19 shared ✅、?13 PIE 今天 ❌、C PIE ✅）；② 三字段 alias **不是**根因（A 回退后仍挂）；③ **W1 杀手窗口 = 08-17→09-16 的 core diff**（fork→09-10 的 949 行 + #127 + #138）；④ ?v=13 本身不稳（D 原字节今天挂），C 与 D 的 128B 差异（当年构建的定制重放内容 vs 我们的重放）是 C 成 D 败的直接原因——**待挖 P2**。
- **v19（09-26 19:3x 部署，线上逐字节验证毕）**：主 `ghostlock.so?v=19`（80632B）= **C 的成功配方 + 09-23 全部 48 内核表**（50 表是 v21 吸收 09-25 才有）（09-16 core 1145ef2d + 10001ae kernels + LMK + constructor，PIE+strip）——新设备支持恢复、小米 17 全链配方固化。构建配方已 pin 进 `build-ghostlock.sh`（CORE_REF/KERNELS_REF），patch 重新生成。
- **v21 静态验证链（09-27 13:2x，无 6.1 真机，TA 授权自主定案）**——六环证据：
  ① C 语义：`tcp ? SLIDE_X : X` 在 tcp=0 求值=原常量（v19 行为，语言级保证，pselect 路线零语义变化）；
  ② 取值域：`tcp_route_selected()` 返回 bool（`GHOSTLOCK_TCP_ROUTE=0` 强制 pselect，否则表字段 `compact_waiter`）∈{0,1}；
  ③ 路由数据：6.1 宏全家 `compact_waiter=1`（Tensor/tcp→alias），6.12/6.6 宏不带（默认 0，QCOM/pselect→image）——按内核线天然分流，50 表零改动自动正确；
  ④ 模式同构：条件化三行与同函数上游既有 5 处 `tcp ? A : B`（SKB_DELTA/chunk_bias/cred_copy_off 等）同构，非发明新模式；
  ⑤ 二进制落点：csel 61→68、指令 9366→9415（+49=三字段常量装载+csel），条件选择确认进产物（v19/v21 字节 diff 因 LTO 布局漂移不可用，改用指令级）；
  ⑥ 上游自证：9e750039 注释原话"the tcp route already uses SLIDE_INIT_TASK the same way"——TCP 路径用 SLIDE 视图是上游自己的一致做法，Tensor G4 的 alias 是必需（commit message）。
  **结论**：v21 对小米 17（pselect）语言级等价于 v19，对 6.1 家族从"纸面必挂"变"上游 09-23+ 事实形态"。判据=期望值严格占优，保持 v21 上线。首台 6.1 真机（vivo T4/Pixel 9/红魔/TB375FC）验证时留意 W1 日志。
- **v21（09-27 13:1x，吸收上游 + 堵 6.1.162 适配缺口）**：上游 09-25 三新提交（IQOO 12 / TB375FC / TB323FU）**零 core 改动**按配方安全吸收，表 48→50、设备 52→55。同时修复真适配缺口：Pixel 9a/9 Pro（6.1.162 Tensor G4）在 09-16 core 下是纸面支持——上游 9e750039 的 alias 改动正是为 Tensor G4 的 Image 特殊加载方式而生（commit message 明说）。落 **route 条件化**（v16 思路 + C 版实证 core）：pselect/QCOM→image 视图（小米 17 实证）、TCP/Tensor→alias 视图（上游 9e750039 形态）。81304B/50 表，线上 cmp 验证毕。**注意：route 条件化后 TCP 路线的行为与上游 09-16 时代不同（老 Tensor 从 image 切 alias，上游论据=同物理页无害）——首台 6.1 设备真机验证时留意**。
- **v20（09-26 20:2x 收尾）**：TA 真机复测 v19 确认**全链成功**（W2 数十秒完成；"日志短"= 成功得快，失败版才把 120s 超时跑满后 dump 尾部）。实验条目与实验 so（cal/a/b/c/d）已清（git 可回溯：v17=eae306b / v18=02d9602），manifest v20 = 52 设备。
- **双 so 钉死（09-27 13:16 TA 确认"小米 17 实测可以了"之后落地，61667da）**：TA 风险偏好=实测凭据最值钱，"实测过的别动"——v21 虽有六环语义等价证明，TA 仍要求小米 17 走原字节。落地：`so/ghostlock-v19.so`（80632B，与 b68828c 提交的 v19 so 逐字节 cmp 相同，即 TA 09-26 20:21 确认成功时线上的同一串字节）；manifest 逐设备路由 so——小米 17 条目 → `ghostlock-v19.so?v=19`，其余 54 → `ghostlock.so?v=21`（GhostLock 组内；IonStack 组 10 台走各自独立 so，与本路由无关）。**字节链闭环**：v19 提交 18:42 → TA 确认 20:21（间隔 99 分钟）→ v20 清理未动 so → 钉死文件 cmp 全等。线上验证：v19 文件 80632B 线上==本地 ✓、manifest 路由 1→v19 + 54→v21 ✓。**红线：ghostlock-v19.so 永不重建/覆盖/移动；任何 manifest 改动不得把小米 17 条目的 so 字段改走 v21**。

### 7.2 蓝牙掉配对（已知机理，非 bug）
提权时 SELinux enforcing↔permissive 反复横跳 + `load_policy` 热重载 → 蓝牙栈内存态丢失 link key → 连接需重新 SSP 配对。**新版不改善**，是临时 root 的固有代价。

### 7.3 K60（内核 5.10）不可行（已终结）
CVE-2026-43499 的 pselect 路线在 5.10 不可行：pselect fd_set 与 futex waiter 栈相对 **delta = -32**（要求 ≥ 0），偏移全对也会 panic（5.10 栈生长方向与 6.x 相反）。K60 已从 manifest 下架。

---

## 8. 部署与回滚

- 构建：`scripts/build-ghostlock.sh`（clone 上游 → pin `CORE_REF=1145ef2d / KERNELS_REF=3bd95d3` → apply `ghostlock-local-0923.patch` → NDK/ONDK clang 编译）；patch 与基线强绑定，换基线必须手动重放并重新生成 patch。**上游 main 已换代（09-28 核查），换基线前先读 §10 待办第 2 条**
- 部署：`git push`（so + manifest 同步，`?v=` 递增破缓存）
- **当前线上基线（v21 双 so 架构，2026-09-27 起）**：主 `ghostlock.so?v=21`（81304B/50 表，PIE+strip，GhostLock 组 54 台）+ `ghostlock-v19.so?v=19`（80632B 原字节，小米 17 专用，永不改动）。~~v17 对照期基线（主 ?v=17 + cal/b 实验件）~~ 实验件已于 v20 清理，git 可回溯（v17=eae306b / v18=02d9602）。历史回退点：v15=e1b7033（08-19 so，22 设备）、v16=a13c4c8（-shared 形态，已弃）、v19=b68828c（小米 17 实测配方，=钉死文件）

## 9. 测试方法（判读规程）

**当前线上判读**（v21 双 so）：
- 小米 17 走 v19 原字节——日志应与 09-26 成功轮一致（W1 一击 5.7s 量级、W2 数十秒、late-load exit=0）。**若小米 17 突然失败，先怀疑环境（系统更新/Firefox 版本），不是 so**——它的字节从未变过
- 其余设备走 v21 条件化：pselect/QCOM 路线日志应见 `payload task view: kernel image`，TCP/Tensor（6.1 家族）应见 alias 形态；首台 6.1 真机验证时留意 W1（§7.1 v21 节的注意项）

~~**v17 实验判读表**（三版同时在线，设备选择器里选不同条目测）~~（实验件已清，判读表留档备用——若再做对照实验可参考此表结构）：

| 先测 | 结果 | 结论 → 下一步 |
|---|---|---|
| 【校准：08-19 原版】 | ❌ 挂 | **环境已变**（系统更新/Firefox/内核侧），停止代码侧折腾，转上游跟踪或换设备 |
| 【校准】✅ → 主条目（A：PIE+回退） | ✅ | 三字段 alias 实锤为根因，修复成立；再测 B 确认 |
| 主条目 ✅ → 【对照B：无回退】 | ✅ | **构建形态是根因**（v14 的挂另有隐情），三字段回退无效；可考虑给上游提形态无关 issue |
| 主条目 ❌ B ❌（校准 ✅） | — | 09-23 源码内还有别的杀手（9e750039 之外）——回到 git 二分，窗口=09-16→09-23 的 kernel 表新增或 e7b81 重建表 |

一般规程：
1. 改完线上后**等约 10 分钟**（CDN），**无痕窗口**，确认 manifest 版本号
2. 先**重启手机**再测；两次测试间隔 ≥ 5 分钟
3. 日志判读：`payload task view: kernel image`（A 版）/"upstream alias (control build B)"（B 版）确认各自在跑；`[+] SELinux permissive` = W1 过；`pselect success=1` ≠ 写入落点正确

---

## 10. 待办（TODO）

1. ~~[P0]~~ **已完成**（v19/v20 真机确认全链成功，实验条目已清）
2. **[P1·等 TA 拍板] 上游换代应对（2026-09-28 核查，TA 指令原文："如果是修复某些功能的跟我说，等我确认之后再更新"）**：
   - 上游 main 09-23→09-28 变化 = **架构换代**：native C 全量重写为 C++23（route 管线化/namespace 化）、48 张 C 表全删换 64 张 HOCON profile（字段与 C offsets.h 一一对应已抽查确认，可翻译）；分支名 very-not-stable-dev，merge 进 main 于 09-28 09:03
   - 上游功能修复清单（在新架构里）：futex 表按 possible CPUs 计数（对部分 W1 失败可能有利）/ KernelSU 已加载跳过注入 / cred 引用计数上限 / multicast 竞态两连修 / root 脚本路径 EFAULT 修复 / Xperia 1 V 5.15 内核线支持
   - 稳定性信号**红**：上游门禁记录有同构建 PASS→panic→PASS 循环、多轮 revert
   - 已给 TA 三选项（09-28 汇报）：A 不动（我推荐，~~v21 65 设备~~ 现 74 设备独立运转不受影响）/ B 只翻译吸收新设备表 / C 跟进新架构（不建议）。
   - **10-16 拍板：TA 授权"你看着搞吧"→ B 选项执行完毕**。10-16 复查上游稳定（47 提交零 panic）后翻译吸收 9 张有效表（5.15×6 跳过），v22 上线（2405f4b）；RootTool 同步 16 张表（7 老差量+9 新翻译）出 v14。后续上游新表按 §5.5 管线增量吸收，core 冻结不变
3. **[P2]** C vs D 的 128B 差异挖矿：反汇编对比定位当年 ?v=13 构建与复刻的定制差异（spray 参数？constructor 形态？）——弄清"当年构建引入了什么坑"
4. **[P2]** 09-16→09-23 core 的 W1 杀手精确定位（当年判 9e750039 已证伪）：二分 fork→09-10 的 949 行 diff（TCP route / W2W3 harden / kernelsnitch / retry 链）；定位后可考虑向上游提 issue 或把 09-16 core 的关键部分前向移植
5. **[P1]** 6.1 compact 设备（TCP route）在 09-16 core 上回归验证——v19/v21 用 09-16 core + route 条件化，若 Tensor/6.1 用户报障需评估
6. ~~上游持续有新提交，下次 sync 只取 kernels/（表），core 冻结在 1145ef2d 直到 W1 杀手定位~~ **已失效（09-28 换代核查）：上游 kernels/*/offsets.h 已全删，"只取表"无从谈起。新表要经 HOCON→C offsets 翻译（字段一一对应，§10.2 选项 B）；core 冻结在 1145ef2d 直到 W1 杀手定位不变**

---

## 11. 关联文档

- APK 侧交接：私有仓库 **`RootTool`** → `AI_HANDOFF.md`（含 CI 构建、签名、extract_rs、本地卡刷包解析等）
