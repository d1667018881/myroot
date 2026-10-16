#!/usr/bin/env python3
"""HOCON kernel profile -> C offsets.h translator (myroot dual-repo).

Reads the 9 new upstream HOCON profiles (post-09-25 additions) and emits
C-style OFFSETS_ENTRY tables compatible with the frozen 09-16 C core
(struct kernel_offsets in src/kernels/offsets.h @ 3bd95d3).

Mapping (verified 2026-10-16):
  release                        -> OFFSETS_ENTRY arg1 / uname_r
  kernel_phys_load (non-null)    -> .kernel_phys_load (main.c:112 honors it)
  route.select_stack.waiter_shift-> .pselect_waiter_shift
                                     (null -> family default; all-old-tables
                                      write it explicitly, so do we)
  offset.init_task/init_cred/root_task_group/selinux_enforcing/
        selinux_blob_sizes/security_hook_heads/slide_nfulnl_logger/
        slide_loggers_0_1/slide_boot_id -> .off_* (all written)
  task_struct.{15 fields}        -> .task_* (only when != family default)
  kernelsnitch.mm_struct_sz      -> .mm_struct_sz (only when != family default)
Dropped (no C-side equivalent, matches the 50 legacy tables' shape):
  kernel_phys_offset (C hardcodes P0_PHYS_OFFSET=0x80000000; legacy HOCON
    tables are null anyway), offset.empty_zero_page (C++-only), cred.{...}
    (C++ cred-forgery params), kernelsnitch.collisions, fallback.{...},
    route.tcp_zerocopy.compact_waiter (family macro already sets it),
    recommend_shizuku, schema_version, kernel_major.
"""
import re, sys, os, json

# family defaults from STRUCT_OFFSETS_* macros (3bd95d3:src/kernels/offsets.h)
FAMILY = {
    "6.1": dict(macro="STRUCT_OFFSETS_6_1",
        waiter_shift=1, mm_struct_sz=0x400, compact_waiter=1,
        task=dict(prio=0x84, normal_prio=0x8C, sched_task_group=0x348,
                  pi_lock=0x924, pi_waiters=0x938, pi_top_task=0x948,
                  pi_blocked_on=0x950, pid=0x630, tgid=0x634,
                  atomic_flags=0x5F0, real_cred=0x830, cred=0x838,
                  comm=0x848, tasks=0x550, seccomp=0x900)),
    "6.6": dict(macro="STRUCT_OFFSETS_6_6",
        waiter_shift=-2, mm_struct_sz=None, compact_waiter=0,
        task=dict(prio=0x84, normal_prio=0x8C, sched_task_group=0x348,
                  pi_lock=0x90C, pi_waiters=0x920, pi_top_task=0x930,
                  pi_blocked_on=0x938, pid=0x618, tgid=0x61C,
                  atomic_flags=0x5D8, real_cred=0x818, cred=0x820,
                  comm=0x830, tasks=0x550, seccomp=0x8E8)),
    "6.12": dict(macro="STRUCT_OFFSETS_6_12",
        waiter_shift=0, mm_struct_sz=None, compact_waiter=0,
        task=dict(prio=0x94, normal_prio=0x9C, sched_task_group=0x420,
                  pi_lock=0x9EC, pi_waiters=0xA00, pi_top_task=0xA10,
                  pi_blocked_on=0xA18, pid=0x708, tgid=0x70C,
                  atomic_flags=0x6C8, real_cred=0x8F8, cred=0x900,
                  comm=0x910, tasks=0x638, seccomp=0x9C8)),
}
OFF_MAP = [  # HOCON offset.{key} -> C .off_{field}
    ("init_task", "off_init_task"),
    ("init_cred", "off_init_cred"),
    ("root_task_group", "off_root_task_group"),
    ("selinux_enforcing", "off_selinux_enforcing"),
    ("selinux_blob_sizes", "off_selinux_blob_sizes"),
    ("security_hook_heads", "off_security_hook_heads"),
    ("slide_nfulnl_logger", "off_slide_nfulnl_logger"),
    ("slide_loggers_0_1", "off_slide_loggers_0_1"),
    ("slide_boot_id", "off_slide_boot_id"),
]
TASK_MAP = [  # HOCON task_struct.{key} -> C .task_{field}
    ("prio", "task_prio"), ("normal_prio", "task_normal_prio"),
    ("sched_task_group", "task_sched_task_group"),
    ("pi_lock", "task_pi_lock"), ("pi_waiters", "task_pi_waiters"),
    ("pi_top_task", "task_pi_top_task"), ("pi_blocked_on", "task_pi_blocked_on"),
    ("pid", "task_pid"), ("tgid", "task_tgid"),
    ("atomic_flags", "task_atomic_flags"),
    ("real_cred", "task_real_cred"), ("cred", "task_cred"),
    ("comm", "task_comm"), ("tasks", "task_tasks"), ("seccomp", "task_seccomp"),
]

def parse_hocon(path):
    """Tiny HOCON subset parser: dotted nesting via braces, key = value."""
    root, stack = {}, []
    cur = root
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # compact one-liner: foo { bar = 1 }
        m = re.match(r"^(\w+)\s*\{\s*(\w+)\s*=\s*(.+?)\s*\}$", line)
        if m:
            cur.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
            continue
        if line.endswith("{"):
            key = line[:-1].strip()
            nxt = {}
            cur[key] = nxt
            stack.append(cur); cur = nxt
            continue
        if line == "}":
            cur = stack.pop()
            continue
        m = re.match(r"^(\w+)\s*=\s*(.+)$", line)
        if m:
            cur[m.group(1)] = m.group(2).strip()
    return root

def val(v):
    if v is None or v == "null":
        return None
    try:
        return int(v)
    except ValueError:
        return v  # quoted strings etc.

def translate(path):
    cfg = parse_hocon(path)
    rel = cfg["release"].strip('"')
    fam_key = ".".join(rel.split(".")[:2])          # "6.1" / "6.6" / "6.12"
    fam = FAMILY[fam_key]
    fields = []
    # waiter_shift: HOCON value or family default, always explicit (legacy style)
    ws = val((cfg.get("route", {}).get("select_stack") or {}).get("waiter_shift"))
    ws = fam["waiter_shift"] if ws is None else ws
    fields.append(".pselect_waiter_shift = %d" % ws)
    # kernel_phys_load
    kpl = val(cfg.get("kernel_phys_load"))
    if kpl:
        fields.append(".kernel_phys_load = 0x%XULL" % kpl)
    # offset.* -> .off_* (always all-written)
    off = cfg.get("offset", {})
    for key, cfield in OFF_MAP:
        v = val(off.get(key))
        if v is None:
            raise SystemExit("FATAL %s: offset.%s missing" % (rel, key))
        fields.append(".%s = 0x%08X" % (cfield, v))
    # task_struct.*: only diffs vs family default
    ts = cfg.get("task_struct", {})
    for key, cfield in TASK_MAP:
        v = val(ts.get(key))
        d = fam["task"].get(key)
        if v is None:
            if d is None:
                continue          # HOCON null and family has no default: skip
        elif v == d:
            continue              # same as family default: skip (macro covers)
        fields.append(".%s = 0x%X" % (cfield, v))
    # mm_struct_sz
    msz = val((cfg.get("kernelsnitch") or {}).get("mm_struct_sz"))
    if msz is not None and msz != fam["mm_struct_sz"]:
        fields.append(".mm_struct_sz = 0x%X" % msz)
    body = ",\n    ".join(fields)
    out = "/* %s */\n\nOFFSETS_ENTRY(\n    \"%s\",\n    %s,\n    %s,\n),\n" % (
        rel, rel, fam["macro"], body)
    return rel, out

if __name__ == "__main__":
    pool, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    registry = []
    for f in sorted(os.listdir(pool)):
        if not f.endswith(".conf"):
            continue
        rel, text = translate(os.path.join(pool, f))
        d = os.path.join(outdir, rel)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "offsets.h"), "w").write(text)
        registry.append(rel)
        print("ok  %-58s fields:%d" % (rel, text.count("= 0x") + 1))
    json.dump(registry, open(os.path.join(outdir, "_registry.json"), "w"), indent=1)
    print("\n%d tables -> %s" % (len(registry), outdir))
