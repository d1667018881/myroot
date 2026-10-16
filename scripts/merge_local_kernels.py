#!/usr/bin/env python3
"""Register local kernel tables into the build tree's known_offsets array.

Runs with cwd = the build workspace (ghostlock-app checkout). Idempotent:
skips includes already present. Anchor: the `{ .uname_r = NULL }`
terminator line of known_offsets in src/kernels/offsets.h.
"""
import glob
import os
import re
import sys

SRC = "src/kernels/offsets.h"
LOCAL_ROOT = os.environ.get(
    "LOCAL_KERNELS_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kernels-local"),
)

def main():
    text = open(SRC).read()
    includes = []
    for d in sorted(glob.glob(os.path.join(LOCAL_ROOT, "*", "offsets.h"))):
        rel = os.path.basename(os.path.dirname(d))
        inc = '#include "%s/offsets.h"' % rel
        if inc not in text:
            includes.append(inc)
    if not includes:
        print("merge_local_kernels: nothing to register")
        return
    if "  { .uname_r = NULL }" not in text:
        sys.exit("merge_local_kernels: anchor terminator not found!")
    array_open = "static const struct kernel_offsets known_offsets[] = {"
    if array_open not in text:
        sys.exit("merge_local_kernels: array opener not found!")
    # local includes go right after the array opener (same spot upstream
    # lists its own table includes); #include must not appear inside the
    # initializer list.
    idx = text.index(array_open) + len(array_open)
    block = "\n".join(includes) + "\n"
    text = text[:idx] + "\n" + block + text[idx:]
    open(SRC, "w").write(text)
    print("merge_local_kernels: registered %d tables" % len(includes))
    for inc in includes:
        print("  " + inc)

if __name__ == "__main__":
    main()
