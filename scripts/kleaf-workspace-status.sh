#!/usr/bin/env bash
# Preserve truthful SCM metadata for the pinned Pixel 8 GKI source plus the
# exact, narrowly-scoped RTL8187 KMI source delta. All status data is generated
# by Google's own workspace_status_stamp.py; this wrapper only validates it.
set -Eeuo pipefail

BUILDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT="$BUILDER_ROOT/workspace"
cd "$ROOT"
if [[ ! -f "$ROOT/WORKSPACE" ]]; then
  echo "ERROR: Bazel workspace root is not the expected Pixel kernel workspace: $ROOT" >&2
  exit 1
fi
PINNED_COMMIT="fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462"
BUILD="14691759"
MANIFEST="$ROOT/out/manifest.xml"

# Bazel may reuse a server started by an earlier query step. Set the exact
# status-command environment here rather than relying on the server's inherited
# environment from the GitHub Actions client.
if [[ -n "${KERNEL_COMMON_COMMIT:-}" && "$KERNEL_COMMON_COMMIT" != "$PINNED_COMMIT" ]]; then
  echo "ERROR: workflow kernel/common pin conflicts with SCM stamp pin." >&2
  exit 1
fi
if [[ -n "${BUILD_NUMBER:-}" && "$BUILD_NUMBER" != "$BUILD" ]]; then
  echo "ERROR: inherited BUILD_NUMBER conflicts with pinned GKI build." >&2
  exit 1
fi
if [[ -n "${KLEAF_REPO_MANIFEST:-}" && "$(realpath "$KLEAF_REPO_MANIFEST")" != "$(realpath "$MANIFEST")" ]]; then
  echo "ERROR: inherited Kleaf Repo manifest points to a different file." >&2
  exit 1
fi
if [[ -n "${KLEAF_USE_KLEAF_LOCALVERSION:-}" && "$KLEAF_USE_KLEAF_LOCALVERSION" != "true" ]]; then
  echo "ERROR: refusing to run with Kleaf localversion calculation disabled." >&2
  exit 1
fi
export KERNEL_COMMON_COMMIT="$PINNED_COMMIT"
export BUILD_NUMBER="$BUILD"
export KLEAF_REPO_MANIFEST="$MANIFEST"
export KLEAF_USE_KLEAF_LOCALVERSION="true"
if [[ ! -s "$KLEAF_REPO_MANIFEST" ]]; then
  echo "ERROR: pinned Repo manifest is missing or empty: $KLEAF_REPO_MANIFEST" >&2
  exit 1
fi

ACTUAL_HEAD="$(git -C "$ROOT/aosp" rev-parse HEAD)"
if [[ "$ACTUAL_HEAD" != "$PINNED_COMMIT" ]]; then
  echo "ERROR: kernel/common HEAD changed before SCM stamping: $ACTUAL_HEAD" >&2
  exit 1
fi

EXPECTED_FILES="$(printf '%s\n' \
  'drivers/net/wireless/realtek/rtl818x/rtl8187/dev.c' \
  'drivers/net/wireless/realtek/rtl818x/rtl8187/rfkill.c' \
  'drivers/net/wireless/realtek/rtl818x/rtl8187/rfkill.h' | LC_ALL=C sort)"
ACTUAL_FILES="$(git -C "$ROOT/aosp" diff --name-only | LC_ALL=C sort)"
if [[ "$ACTUAL_FILES" != "$EXPECTED_FILES" ]]; then
  echo "ERROR: kernel/common has an unexpected tracked source diff; refusing to accept this SCM state." >&2
  echo "Expected changed files:" >&2
  printf '%s\n' "$EXPECTED_FILES" >&2
  echo "Actual changed files:" >&2
  printf '%s\n' "$ACTUAL_FILES" >&2
  exit 1
fi
git -C "$ROOT/aosp" diff --check

TMP_STATUS="$(mktemp)"
trap 'rm -f "$TMP_STATUS"' EXIT

# Match Google's workspace_status.sh: emit the common build keys first, then
# call the pinned Kleaf SCM collector with the exact Repo manifest.
"$ROOT/build/kernel/kleaf/workspace_status_common.sh"
PYTHON="$ROOT/prebuilts/build-tools/path/linux-x86/python3"
if [[ -x "$PYTHON" ]]; then
  "$PYTHON" "$ROOT/build/kernel/kleaf/workspace_status_stamp.py" > "$TMP_STATUS"
else
  python3 "$ROOT/build/kernel/kleaf/workspace_status_stamp.py" > "$TMP_STATUS"
fi

python3 - "$TMP_STATUS" "$PINNED_COMMIT" "$BUILD" <<'PY'
import json
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
commit = sys.argv[2]
build = sys.argv[3]
lines = status_path.read_text().splitlines()
prefix = "STABLE_SCMVERSIONS "
matches = [line for line in lines if line.startswith(prefix)]
if len(matches) != 1:
    raise SystemExit(
        f"ERROR: expected one {prefix.strip()} record from official Kleaf status; found {len(matches)}"
    )

versions = json.loads(matches[0][len(prefix):])
observed = versions.get("aosp")
expected_dirty = f"-g{commit[:12]}-dirty-ab{build}"
if observed != expected_dirty:
    raise SystemExit(
        "ERROR: Kleaf's observed aosp SCM value differs from the one permitted "
        f"for the pinned RTL8187 patch: expected {expected_dirty!r}, observed {observed!r}"
    )

# The dirty suffix is intentional and truthful: these are the three
# verified KMI-safe RTL8187 source edits on top of the exact pinned GKI commit.
# Retain it, along with the exact GKI build number; do not rewrite SCM identity.
for line in lines:
    print(line)
PY
