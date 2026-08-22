"""Parse every `run:` block in this repo's workflows with the shell that runs it.

Run on macOS, where /bin/bash is 3.2 -- the same interpreter GitHub's macOS
runners use, and the one that differs from the bash 5 on Linux runners.

This exists because of a real failed release in lohi-ai/agentray: a release step
wrote its notes with `NOTES=$(cat <<EOF ... EOF)`, and bash 3.2 scans a heredoc
body for quotes while looking for the closing paren of a command substitution.
One apostrophe in prose was an unterminated quote and the step exited 2 before
`gh` was ever called. A release workflow is not run by anything until a tag is
pushed, so its shell errors surface at the worst possible moment. This turns that
into a PR failure.

`${{ }}` expressions become a placeholder: this checks shell grammar, not values.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

import yaml

bad = 0
checked = 0
for wf in sorted(glob.glob(".github/workflows/*.yml")):
    for job, spec in yaml.safe_load(open(wf))["jobs"].items():
        for step in spec.get("steps") or []:
            run = step.get("run")
            if not run:
                continue
            fh = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False)
            fh.write(re.sub(r"\$\{\{(.*?)\}\}", "X", run))
            fh.close()
            checked += 1
            proc = subprocess.run(["/bin/bash", "-n", fh.name], capture_output=True, text=True)
            if proc.returncode:
                bad += 1
                label = step.get("name") or run.splitlines()[0][:40]
                print(f"{wf} :: {job} :: {label}")
                print("   ", (proc.stderr.strip().splitlines() or ["parse error"])[0])
            os.unlink(fh.name)

if bad:
    sys.exit(f"{bad} run block(s) will not parse on a runner")

version = subprocess.run(["/bin/bash", "-c", "echo $BASH_VERSION"], capture_output=True, text=True).stdout.strip()
print(f"ok: {checked} run blocks parse under bash {version}")
