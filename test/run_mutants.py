#!/usr/bin/env python3
"""Apply each mutant and require at least one listed test to fail."""
import os, subprocess, sys, yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = yaml.safe_load(open(os.path.join(ROOT, "test/mutants/manifest.yaml")))
alive = []
for m in manifest:
    path = os.path.join(ROOT, "test/mutants", m["file"])
    # A mutant whose mutation is PYTHON-side (the runner's own css parser, say) cannot be
    # expressed as a CREATE OR REPLACE MACRO override, so the manifest may carry an `env` map
    # that is added to the environment of every subprocess run for that mutant; its SQL file is
    # then comment-only. Keys are read by the runner, not by the SQL: see MN08.
    env = dict(os.environ, **{k: str(v) for k, v in (m.get("env") or {}).items()})
    killed_by = []
    for t in m["expect_fail"]:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run.py"), os.path.join(ROOT, t), "--mutant", path],
                           capture_output=True, text=True, env=env)
        if r.returncode != 0:
            killed_by.append(t)
    status = "KILLED" if killed_by else "SURVIVED"
    print(f"{m['id']} {status}: {m['what']}" + (f"  (by {', '.join(killed_by)})" if killed_by else ""))
    if not killed_by:
        alive.append(m["id"])
if alive:
    print("surviving mutants:", ", ".join(alive)); sys.exit(1)
print("all mutants killed")
