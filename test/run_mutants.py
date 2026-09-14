#!/usr/bin/env python3
"""Apply each mutant and require at least one listed test to fail."""
import os, subprocess, sys, yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = yaml.safe_load(open(os.path.join(ROOT, "test/mutants/manifest.yaml")))
alive = []
for m in manifest:
    path = os.path.join(ROOT, "test/mutants", m["file"])
    killed_by = []
    for t in m["expect_fail"]:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run.py"), os.path.join(ROOT, t), "--mutant", path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            killed_by.append(t)
    status = "KILLED" if killed_by else "SURVIVED"
    print(f"{m['id']} {status}: {m['what']}" + (f"  (by {', '.join(killed_by)})" if killed_by else ""))
    if not killed_by:
        alive.append(m["id"])
if alive:
    print("surviving mutants:", ", ".join(alive)); sys.exit(1)
print("all mutants killed")
