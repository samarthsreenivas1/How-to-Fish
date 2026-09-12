#!/usr/bin/env python3
"""Run tools/gen_mesh_colors.py with its OUT redirected to a scratch path.

The tool has no --output flag and writes in place. Rather than write the repo
file and restore it (a window in which the shared checkout is dirty), this
imports the module -- so ROOT, and therefore the assets/ generator paths, stay
correct -- and rebinds the module-level OUT before main() runs.
"""
import sys, os, time

sys.dont_write_bytecode = True
dest = os.path.abspath(sys.argv[1])
sys.argv = [sys.argv[0]]          # main() reads sys.argv[1:]; no --check

sys.path.insert(0, "/Users/samarthsreenivas/Developer/How-to-Fish/tools")
import gen_mesh_colors as g

REPO_OUT = g.OUT
g.OUT = dest
assert g.OUT != REPO_OUT

start = time.time()
try:
    g.main()
except SystemExit as e:
    print("\n[runner] main() exited %r (conflicts or check-fail)" % (e.code,))
print("[runner] elapsed %.1fs" % (time.time() - start))

# Paranoia: prove the repo file was never opened for write.
print("[runner] repo OUT still at %s" % REPO_OUT)
