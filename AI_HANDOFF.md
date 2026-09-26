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

- **W1 回归根因（已锤定）**：上游 `9e750039`（09-17，"Add Pixel 9 Pro"）把 `util.c` payload 三个字段 `waiter_task`/`task_group`/`pi_top_task` 从 **image 视图**（`INIT_TASK`=`ffffffc0…`）改成 **direct-map alias 视图**（`SLIDE_INIT_TASK`=`ffffff80…`），注释声称 "aliases are dereferenceable on every SoC"。**该论断对 QCOM 6.12 非 compact pselect 路线不成立**——alias 地址本身可写（W1 target 一直是 alias 形式），但 PI 链上 planted task 指针与内核自持的 image 形式指针做身份比较时分叉，erase 写入不再落到 target（`success=1` 只是 consumer 的 sched_setattr 成功，不是写入验证）。v13→v14 之间这是**唯一**碰 `src/core` 的提交（逐 commit 核对过文件列表）。
- **W2 回归（根因仍未定，#127 嫌疑已撤）**：09-16 时代归咎 #127 是**错的**——#127 只改 compact 字表（`relink_pc` 那组），小米 17 走非 compact；非 compact 的 W0 payload 布局、W1/W2 调用参数（mode/leaf）、写入字表在 fork(08-17)→09-16 之间**文本上完全没变**。真正的回归窗口是 **fork→09-10 的 949 行大 diff**（TCP route 引入 + "W2/W3 harden" + kernelsnitch 大改 + W2/W3 改三轮 retry 链 + `pselect_child_node`/perf leak 流程调整），具体哪一处杀的 W2 未定位。另一个未排除假说：perf_find_task 泄漏到错误 task（写入落了但 verify 读的 child 不对）。
- **止血→根治（2026-09-26）**：先部署 v15 回滚（08-19 so）止血；同日 TA 否决回滚方案（丢新设备）→ **v16 forward fix**：上游 10001ae1 全量源码 + `scripts/ghostlock-local-0923.patch`（LMK 定制 + constructor 入库 + W1 视图修复）本地重建，so=110832B/48 内核表（与 v14 逐串一致），manifest v16 恢复全部 52 设备，`?v=16`。修复内容：`util.c` 三字段改 `tcp ? SLIDE_INIT_TASK : INIT_TASK`（TCP/Tensor 保 alias，pselect/QCOM 恢复 image），新增日志 `payload task view: kernel image|direct-map alias` 可在真机日志确认修复版在跑。
- **v16 附带还清的交接债**：08-19 手动构建注入的 constructor+unsetenv（`ghostlock_preload_init`）从未入库——v14 的 so 里也有此符号但 patch/脚本都没有，属于"能跑但不可复现"。现已入 patch，`build-ghostlock.sh` 同步重写（pin 到 UPSTREAM_REF=10001ae1）。
- **W2 残留风险（未解）**：v16 只修 W1。小米 17 在 09-16 基线上还有"W1 过、W2 挂"的遗留回归（窗口=fork→09-10 的 949 行 diff，根因未定位）。v16 若复现此症状（日志走到 `W2: cred` 反复重试但 `child uid` 不变），下一步按 §10 P2 排查。

### 7.2 蓝牙掉配对（已知机理，非 bug）
提权时 SELinux enforcing↔permissive 反复横跳 + `load_policy` 热重载 → 蓝牙栈内存态丢失 link key → 连接需重新 SSP 配对。**新版不改善**，是临时 root 的固有代价。

### 7.3 K60（内核 5.10）不可行（已终结）
CVE-2026-43499 的 pselect 路线在 5.10 不可行：pselect fd_set 与 futex waiter 栈相对 **delta = -32**（要求 ≥ 0），偏移全对也会 panic（5.10 栈生长方向与 6.x 相反）。K60 已从 manifest 下架。

---

## 8. 部署与回滚

- 构建：`scripts/build-ghostlock.sh`（clone 上游 → pin `UPSTREAM_REF` → apply `ghostlock-local-0923.patch` → NDK/ONDK clang 编译）；patch 与基线强绑定，换基线必须手动重放并重新生成 patch
- 部署：`git push`（so + manifest 同步，`?v=` 递增破缓存）
- **当前线上基线（v16，2026-09-26 起）**：so 110832 / 48 内核 / 52 设备 / `?v=16`。历史回退点：v15=e1b7033（08-19 so，22 设备，小米 17 全链验证态）、v14=8433218（W1 回归版，勿回退）。

---

## 9. 测试方法

1. 改完线上后**等约 10 分钟**（GitHub Pages CDN 缓存），用**无痕窗口**打开；确认 manifest 是 v16
2. 先**重启手机**再测（成功率最高）；两次测试间隔 ≥ 5 分钟
3. 日志判读：`payload task view: kernel image`（QCOM 设备应见此行，确认 v16 修复版在跑）→ `[+] SELinux permissive` = W1 成功 → `[+] child is root!` / KernelSU 激活 = 成功；`pselect success=1` **不代表**写入落点正确（只是 consumer 侧 sched_setattr 成功）

---

## 10. 待办（TODO）

1. **[P0]** v16 真机复测小米 17：预期 W1 恢复（时间线上回到 09-16 行为）；若 W2 仍挂（`W2: cred` 重试但 `child uid` 不变），进入 P2
2. **[P2]** W2 回归根因定位：上游 fork→09-10 的 949 行 diff（TCP route / W2W3 harden / kernelsnitch / 三轮 retry 链）；候选假说：perf_find_task 泄漏错 task
3. **[P3]** 向 `YuKongA/ghostlock-app` 提 issue：9e750039 alias 改动破坏 QCOM 6.12 非 compact pselect 的 W1（证据见 §7.1），建议 route 条件化
4. **[P1]** APK `RootTool` 同步解冻条件达成（上游修复或自带 route 条件化）：同步到 ≥10001ae1 时需重放 v16 的视图修复
5. 上游 09-25/09-26 又有新提交（PD2361 multicast geometry 等），下次 sync 时注意重新审查 core 改动

---

## 11. 关联文档

- APK 侧交接：私有仓库 **`RootTool`** → `AI_HANDOFF.md`（含 CI 构建、签名、extract_rs、本地卡刷包解析等）
