"""Writes the 3.1 gate template - the gate /factory:init wrote into projects
before the engine moved into the plugin - to the path given. The suites use it
for projects that still run it."""
import io, os, shutil, sys
src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "hooks", "legacy", "verify-3.1.sh")
dst = sys.argv[1]
if os.path.dirname(dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
shutil.copyfile(src, dst)
print("lines:", len(io.open(src, encoding="utf-8").read().splitlines()))
