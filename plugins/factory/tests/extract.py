import io, os, re, sys
src = io.open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "commands", "init.md"), encoding="utf-8").read()
fence = "```bash\n#!/usr/bin/env bash\n# Factory quality gate."
s = src.index(fence) + len("```bash\n")
e = src.index("\n```\n\n`chmod +x gates/verify.sh`", s)
body = re.sub(r'\\\$([1-9])', r'$\1', src[s:e])
io.open(sys.argv[1], "w", encoding="utf-8").write(body + "\n")
print("lines:", len(body.splitlines()))
