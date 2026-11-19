#!/usr/bin/env bash
# Build modules against the exact prebuilt GKI kernel release.
# The original status wrapper independently verifies and records the truthful
# dirty source state. Only the aosp SCM suffix used for KERNELRELEASE is
# normalized to the official prebuilt GKI identity, because the kernel Image
# itself is not rebuilt in --use_prebuilt_gki mode.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
STATUS_FILE="$(mktemp)"
trap 'rm -f "$STATUS_FILE"' EXIT

# This performs all pinned-commit, exact-three-file-diff, whitespace, manifest,
# and official Kleaf SCM checks. It must report the real dirty source identity.
"$SCRIPT_DIR/kleaf-workspace-status.sh" > "$STATUS_FILE"

python3 - "$STATUS_FILE" <<'PY'
import json
import sys
from pathlib import Path

PINNED_COMMIT = "fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462"
BUILD = "14691759"
prefix = "STABLE_SCMVERSIONS "
lines = Path(sys.argv[1]).read_text().splitlines()
matches = [line for line in lines if line.startswith(prefix)]
if len(matches) != 1:
    raise SystemExit("ERROR: expected exactly one official STABLE_SCMVERSIONS record")

versions = json.loads(matches[0][len(prefix):])
actual = versions.get("aosp")
expected_dirty = f"-g{PINNED_COMMIT[:12]}-dirty-ab{BUILD}"
expected_gki = f"-g{PINNED_COMMIT[:12]}-ab{BUILD}"
if actual != expected_dirty:
    raise SystemExit(
        f"ERROR: source audit expected {expected_dirty!r}, observed {actual!r}"
    )

# In prebuilt-GKI mode, the Image is the immutable official build. Modules
# must therefore carry that exact kernel release in vermagic. The source diff
# remains independently recorded as dirty by kleaf-workspace-status.sh and
# the build report; this is not a claim that the source checkout is clean.
versions["aosp"] = expected_gki
for line in lines:
    if line.startswith(prefix):
        print(prefix + json.dumps(versions, separators=(",", ":")))
    else:
        print(line)

print(
    "PREBUILT_GKI_KERNELRELEASE_STAMP "
    f"aosp={expected_gki} source_audit={expected_dirty}"
)
PY
