# AI 交接文档 — myroot（网页版临时 Root）

> 面向接手的 AI / 开发者的**技术交接**。
> 同一项目的 **APK 版**（私有仓库 `RootTool`）有对应文档：`RootTool/AI_HANDOFF.md`，两份内容互补、互相引用。
> 最后更新：2026-09-25

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
| `so/ghostlock.so` | 核心提权 so（编译产物，见 §5） |

---

## 2. 引用了谁（上游/来源）

| 来源 | 用途 |
|---|---|
| `YuKongA/ghostlock-app` | **核心**：`src/core/*.c` + `src/kernels/*`（偏移表）→ 编译成 `ghostlock.so` |
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

## 4. 当前状态（基线）

| 项 | 值 |
|---|---|
| `so/ghostlock.so` | **81208 字节**，md5 `0746cb98e2f9d0b800290c5b0be016b8`（记为 **so v14**）|
| `manifest.json` | version **14**，`?v=14`，共 **62 设备**（GhostLock 52 + IonStack 10）|
| 同步基线 | 上游 HEAD `10001ae1`（2026-09-23，**50 内核**）|
| 上一版 | v13 = so 80104 / `?v=13`（**在小米 17 上有 W2 回归，见 §6.1**）|
| **稳定回退基线** | 09-10 版 = so **72432** / manifest v11 / `?v=12`（用户实测可用）|

---

## 5. 构建 so（可复现）

```bash
# 1) 取上游源码
cd /tmp && curl -sL -o up.tar.gz \
  "https://codeload.github.com/YuKongA/ghostlock-app/tar.gz/refs/heads/main"
mkdir up && tar xzf up.tar.gz -C up

# 2) 覆盖到编译区
cd <workdir>/ghostlock-build
cp -r /tmp/up/ghostlock-app-main/src/core/.    src/core/
cp -r /tmp/up/ghostlock-app-main/src/kernels/. src/kernels/
# 3) 重打 §6 的三处定制（common.h / util.c / main.c）

# 4) 编译（产出 PIE 可执行文件）
export ANDROID_NDK_HOME=<path>/android-ndk-r29
make            # SRCS = src/core/{main.c,offsets_json.c,util.c,fops.c}

# 5) 去符号得到 .so
NDK=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin
cp ghostlock ghostlock_vNN.so && $NDK/llvm-strip ghostlock_vNN.so

# 6) 部署：cp 到 so/ghostlock.so，并递增 manifest 的 ?v=
```

> 部署用 GitHub contents API（二进制走 base64）；**so 与 manifest 分两次提交**（合并易超时）。改了 so 必须递增 `?v=`，否则浏览器/CDN 用旧缓存。

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
  | 09-24 v14 so | 10001ae1（含 9e750039） | ❌ **W1 都挂** + 一次 panic（09-26 实测 3 次：2 次 120s 超时卡在 W1 attempt、1 次卡死重启） |

- **W1 回归首版归因（v16 复测后修正：三字段 alias 是**嫌疑**而非实锤根因）**：上游 `9e750039`（09-17，"Add Pixel 9 Pro"）把 `util.c` payload 三个字段 `waiter_task`/`task_group`/`pi_top_task` 从 **image 视图**（`INIT_TASK`=`ffffffc0…`）改成 **direct-map alias 视图**（`SLIDE_INIT_TASK`=`ffffff80…`）。v13→v14 之间它是唯一碰 `src/core` 的提交（逐 commit 核对过文件列表）——这是事实；但"alias 破坏 PI 链"的机制推断（planted task 指针与 image 形式指针身份比较分叉）**未被 v16 复测证实**（image 视图回退后 W1 仍挂），v16 的挂更可能由构建形态差异（-shared）引入。注意 `success=1` 只是 consumer 的 sched_setattr 成功，不是写入验证——这条判读依然成立。
- **W2 回归（根因仍未定，#127 嫌疑已撤）**：09-16 时代归咎 #127 是**错的**——#127 只改 compact 字表（`relink_pc` 那组），小米 17 走非 compact；非 compact 的 W0 payload 布局、W1/W2 调用参数（mode/leaf）、写入字表在 fork(08-17)→09-16 之间**文本上完全没变**。真正的回归窗口是 **fork→09-10 的 949 行大 diff**（TCP route 引入 + "W2/W3 harden" + kernelsnitch 大改 + W2/W3 改三轮 retry 链 + `pselect_child_node`/perf leak 流程调整），具体哪一处杀的 W2 未定位。另一个未排除假说：perf_find_task 泄漏到错误 task（写入落了但 verify 读的 child 不对）。
- **止血→根治（2026-09-26）**：先部署 v15 回滚（08-19 so）止血；同日 TA 否决回滚方案（丢新设备）→ **v16 forward fix**：上游 10001ae1 全量源码 + `scripts/ghostlock-local-0923.patch`（LMK 定制 + constructor 入库 + W1 视图修复）本地重建，so=110832B/48 内核表（与 v14 逐串一致），manifest v16 恢复全部 52 设备，`?v=16`。修复内容：`util.c` 三字段改 `tcp ? SLIDE_INIT_TASK : INIT_TASK`（TCP/Tensor 保 alias，pselect/QCOM 恢复 image），新增日志 `payload task view: kernel image|direct-map alias` 可在真机日志确认修复版在跑。
- **v16 附带还清的交接债**：08-19 手动构建注入的 constructor+unsetenv（`ghostlock_preload_init`）从未入库——v14 的 so 里也有此符号但 patch/脚本都没有，属于"能跑但不可复现"。现已入 patch，`build-ghostlock.sh` 同步重写（pin 到 UPSTREAM_REF=10001ae1）。
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
- **v19（09-26 19:3x 部署，线上逐字节验证毕）**：主 `ghostlock.so?v=19`（80632B）= **C 的成功配方 + 09-23 全部 50 内核表**（09-16 core 1145ef2d + 10001ae1 kernels + LMK + constructor，PIE+strip）——新设备支持恢复、小米 17 全链配方固化。构建配方已 pin 进 `build-ghostlock.sh`（CORE_REF/KERNELS_REF），patch 重新生成。
- **v20（09-26 20:2x 收尾）**：TA 真机复测 v19 确认**全链成功**（W2 数十秒完成；"日志短"= 成功得快，失败版才把 120s 超时跑满后 dump 尾部）。实验条目与实验 so（cal/a/b/c/d）已清（git 可回溯：v17=eae306b / v18=02d9602），manifest v20 = 52 设备。

### 7.2 蓝牙掉配对（已知机理，非 bug）
提权时 SELinux enforcing↔permissive 反复横跳 + `load_policy` 热重载 → 蓝牙栈内存态丢失 link key → 连接需重新 SSP 配对。**新版不改善**，是临时 root 的固有代价。

### 7.3 K60（内核 5.10）不可行（已终结）
CVE-2026-43499 的 pselect 路线在 5.10 不可行：pselect fd_set 与 futex waiter 栈相对 **delta = -32**（要求 ≥ 0），偏移全对也会 panic（5.10 栈生长方向与 6.x 相反）。K60 已从 manifest 下架。

---

## 8. 部署与回滚

- 构建：`scripts/build-ghostlock.sh`（clone 上游 → pin `UPSTREAM_REF` → apply `ghostlock-local-0923.patch` → NDK/ONDK clang 编译）；patch 与基线强绑定，换基线必须手动重放并重新生成 patch
- 部署：`git push`（so + manifest 同步，`?v=` 递增破缓存）
- **当前线上基线（v17 三版对照，2026-09-26 起）**：主 `ghostlock.so?v=17`（PIE+回退，81336B/48 内核）+ `ghostlock-cal.so`（08-19 原版校准）+ `ghostlock-b.so`（无回退对照）。历史回退点：v15=e1b7033（08-19 so，22 设备）、v16=a13c4c8（-shared 形态，已弃）

---

## 9. 测试方法（v17 三版对照判读）

**v17 实验判读表**（三版同时在线，设备选择器里选不同条目测）：

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
2. **[P2]** C vs D 的 128B 差异挖矿：反汇编对比定位当年 ?v=13 构建与复刻的定制差异（spray 参数？constructor 形态？）——弄清"当年构建引入了什么坑"
3. **[P2]** 09-16→09-23 core 的 W1 杀手精确定位（当年判 9e750039 已证伪）：二分 fork→09-10 的 949 行 diff（TCP route / W2W3 harden / kernelsnitch / retry 链）；定位后可考虑向上游提 issue 或把 09-16 core 的关键部分前向移植
4. **[P1]** 6.1 compact 设备（TCP route）在 09-16 core 上回归验证——v19 用 09-16 core，若 Tensor/6.1 用户报障需评估
5. 上游持续有新提交，下次 sync 只取 kernels/（表），core 冻结在 1145ef2d 直到 W1 杀手定位

---

## 11. 关联文档

- APK 侧交接：私有仓库 **`RootTool`** → `AI_HANDOFF.md`（含 CI 构建、签名、extract_rs、本地卡刷包解析等）
