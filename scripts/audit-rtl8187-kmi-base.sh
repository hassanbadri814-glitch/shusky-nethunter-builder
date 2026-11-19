#!/usr/bin/env bash
# Prove the exact pinned GKI already exports the USB/network symbols through
# Google's published virtual_device ABI. This does not alter the Pixel ABI.
set -Eeuo pipefail
ROOT="${1:?Android kernel source root required}"
REPORT_DIR="${2:?report directory required}"
GKI_BUILD_ID="${3:-14691759}"
ABI="$ROOT/android/abi_gki_aarch64_virtual_device"
GKI_BUILD="$ROOT/BUILD.bazel"
SYMVERS="$REPORT_DIR/gki-vmlinux.symvers"
REPORT="$REPORT_DIR/rtl8187-gki-virtual-device-abi.txt"
mkdir -p "$REPORT_DIR"
for f in "$ABI" "$GKI_BUILD"; do
  test -s "$f" || { echo "ERROR: required official GKI ABI file missing: $f" >&2; exit 1; }
done

# On this Android 6.1 branch, the authoritative GKI symbol-list
# aggregation is maintained in BUILD.bazel, not build.config.gki.aarch64.
# Verify that the official virtual_device list is part of the GKI
# aarch64_additional_kmi_symbol_lists filegroup used by kernel_aarch64.
python3 - "$GKI_BUILD" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
start = text.find('name = "aarch64_additional_kmi_symbol_lists"')
if start < 0:
    raise SystemExit("ERROR: GKI additional KMI symbol-list filegroup missing.")
end = text.find('visibility = ["//visibility:public"]', start)
if end < 0:
    raise SystemExit("ERROR: GKI additional KMI symbol-list filegroup is malformed.")
block = text[start:end]
required = '"android/abi_gki_aarch64_virtual_device"'
if required not in block:
    raise SystemExit("ERROR: pinned GKI filegroup does not include virtual_device ABI.")
kernel_start = text.find('"kernel_aarch64": {')
kernel_end = text.find('"kernel_aarch64_16k": {', kernel_start)
kernel_block = text[kernel_start:kernel_end]
if '":aarch64_additional_kmi_symbol_lists"' not in kernel_block:
    raise SystemExit("ERROR: kernel_aarch64 does not consume the official additional KMI list filegroup.")
print("Pinned GKI BUILD.bazel virtual_device ABI integration: PASS")
PY

curl -fsSL --retry 3 --retry-delay 2 \
  "https://ci.android.com/builds/submitted/$GKI_BUILD_ID/kernel_aarch64/latest/raw/vmlinux.symvers" \
  -o "$SYMVERS"
test -s "$SYMVERS" || { echo "ERROR: pinned GKI vmlinux.symvers is empty." >&2; exit 1; }

python3 - "$ABI" "$SYMVERS" "$REPORT" <<'PY'
from pathlib import Path
import re, sys
abi_path, symvers_path, report_path = map(Path, sys.argv[1:])
required = [
    "__dev_kfree_skb_irq",
    "usb_alloc_urb",
    "usb_anchor_urb",
    "usb_control_msg",
    "usb_free_urb",
    "usb_kill_anchored_urbs",
    "usb_put_dev",
    "usb_reset_device",
    "usb_submit_urb",
    "usb_unanchor_urb",
]
abi_lines = {line.strip() for line in abi_path.read_text().splitlines()}
exports = {}
for line in symvers_path.read_text(errors="replace").splitlines():
    fields = line.split()
    if len(fields) >= 2 and re.fullmatch(r"(?:0x)?[0-9a-fA-F]{8}", fields[0]):
        exports[fields[1]] = fields[0].lower().removeprefix("0x")
missing_abi = [s for s in required if s not in abi_lines]
missing_gki = [s for s in required if s not in exports]
lines = [
    "Pinned GKI virtual_device ABI source: PASS" if not missing_abi else "Pinned GKI virtual_device ABI source: FAIL",
    f"Required symbols: {len(required)}",
    f"Missing from official virtual_device ABI: {len(missing_abi)}",
    f"Missing from pinned GKI vmlinux.symvers: {len(missing_gki)}",
]
lines += [f"MISSING_ABI {s}" for s in missing_abi]
lines += [f"MISSING_GKI_EXPORT {s}" for s in missing_gki]
lines += [f"GKI_EXPORT {s} CRC={exports[s]}" for s in required if s in exports]
report_path.write_text("\n".join(lines) + "\n")
print(report_path.read_text(), end="")
if missing_abi or missing_gki:
    raise SystemExit("ERROR: exact pinned GKI does not prove the complete official ABI/export set")
PY
