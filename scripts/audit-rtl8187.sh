#!/usr/bin/env bash
# Fail-closed audit for the Shusky RTL8187 module. No device access or flashing.
set -Eeuo pipefail
IFS=$'\n\t'

WORKSPACE="${1:?workspace path required}"
EXPECTED_RELEASE="${2:?expected kernel release required}"
REPORT_DIR="${3:?report directory required}"
CONFIG="${4:?final kernel config path required}"
GKI_BUILD_ID="${5:-14691759}"
mkdir -p "$REPORT_DIR"

fail() { echo "FATAL: $*" >&2; exit 1; }
require_config() {
  grep -qxF "$1" "$CONFIG" || fail "final kernel config lacks exact setting: $1"
}

# Assert the actual merged .config, not just the defconfig fragment.
require_config 'CONFIG_MODULES=y'
require_config 'CONFIG_MODVERSIONS=y'
require_config 'CONFIG_WLAN=y'
require_config 'CONFIG_CFG80211=m'
require_config 'CONFIG_MAC80211=m'
require_config 'CONFIG_USB=y'
require_config 'CONFIG_RTL8187=m'
require_config 'CONFIG_EEPROM_93CX6=m'
require_config 'CONFIG_CRYPTO_FIPS140_MOD=m'
if grep -Eq '^CONFIG_KSU=(y|m)$' "$CONFIG"; then
  fail "CONFIG_KSU must remain disabled"
fi

# Locate the module only in Kleaf kernel staging trees, not arbitrary build files.
mapfile -t MODULES < <(
  find "$WORKSPACE/out/bazel" -type f \
    -path '*/kernel_images_*/staging/lib/modules/*/kernel/drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko' \
    -print | sort -u
)
[ "${#MODULES[@]}" -ge 1 ] || fail "no staged RTL8187 module found"
HASH_COUNT="$(sha256sum "${MODULES[@]}" | awk '{print $1}' | sort -u | wc -l)"
[ "$HASH_COUNT" -eq 1 ] || {
  sha256sum "${MODULES[@]}"
  fail "RTL8187 copies in final staging trees are not byte-identical"
}
MODULE="${MODULES[0]}"

readelf -h "$MODULE" | grep -Eq 'Type:[[:space:]]+REL' || fail "RTL8187 is not an ELF relocatable module"
readelf -h "$MODULE" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail "RTL8187 is not AArch64"
[ "$(modinfo -F name "$MODULE")" = "rtl8187" ] || fail "unexpected module internal name"
RELEASE="$(modinfo -F vermagic "$MODULE" | awk '{print $1}')"
RELEASE="${RELEASE%-ab*}"
[ "$RELEASE" = "$EXPECTED_RELEASE" ] || fail "vermagic $RELEASE != expected $EXPECTED_RELEASE"

# Verify that this module actually advertises the adapter's USB VID:PID.
if ! modinfo -F alias "$MODULE" | grep -Eiq 'usb:v0BDAp8187'; then
  fail "RTL8187 module has no USB alias for Realtek 0BDA:8187"
fi

DEPENDS="$(modinfo -F depends "$MODULE")"
case ",$DEPENDS," in *,mac80211,*) ;; *) fail "mac80211 is not a declared RTL8187 dependency" ;; esac
case ",$DEPENDS," in *,eeprom_93cx6,*) ;; *) fail "eeprom_93cx6 is not a declared RTL8187 dependency" ;; esac

# Every staging copy must have a coherent modules.dep and every direct
# dependency named by modinfo must resolve to a real module in that tree.
for MODULE_PATH in "${MODULES[@]}"; do
  ROOT="${MODULE_PATH%%/kernel/drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko}"
  DEPFILE="$ROOT/modules.dep"
  [ -s "$DEPFILE" ] || fail "missing/empty modules.dep in $ROOT"
  RELPATH="${MODULE_PATH#"$ROOT"/}"
  LINE="$(grep -F "$RELPATH:" "$DEPFILE" || true)"
  [ -n "$LINE" ] || fail "modules.dep lacks exact RTL8187 entry in $ROOT"
  python3 - "$ROOT" "$LINE" "$DEPENDS" <<'PY'
import os, sys
root, line, depends = sys.argv[1:]
lhs, sep, rhs = line.partition(":")
if not sep or not lhs.endswith("/rtl8187.ko"):
    raise SystemExit("ERROR: malformed RTL8187 modules.dep line")
deps = rhs.split()
for item in deps:
    if not os.path.isfile(os.path.join(root, item)):
        raise SystemExit(f"ERROR: modules.dep dependency does not exist: {item}")
dep_names = {os.path.basename(x).removesuffix(".ko") for x in deps}
for name in filter(None, depends.split(",")):
    if name not in dep_names:
        raise SystemExit(f"ERROR: modinfo dependency {name} absent from modules.dep")
PY
  [ -s "$ROOT/kernel/net/mac80211/mac80211.ko" ] || fail "mac80211.ko absent from same staging tree"
  [ -s "$ROOT/kernel/drivers/misc/eeprom/eeprom_93cx6.ko" ] || fail "eeprom_93cx6.ko absent from same staging tree"
done

# This is a hot-plug USB module: it must not be part of early boot modules.load.
if find "$WORKSPACE/out/bazel" -type f -name modules.load -exec grep -lE '(^|/)rtl8187\.ko|(^|/)eeprom_93cx6\.ko' {} + | grep -q .; then
  fail "RTL8187/EEPROM was incorrectly added to early-boot modules.load"
fi

# Cross-check imported symbol CRCs against the exact pinned GKI build and
# this build's Module.symvers. Never merge conflicting CRC definitions.
GKI_SYMVERS="$REPORT_DIR/gki-vmlinux.symvers"
curl -fsSL --retry 3 --retry-delay 2 \
  "https://ci.android.com/builds/submitted/$GKI_BUILD_ID/kernel_aarch64/latest/raw/vmlinux.symvers" \
  -o "$GKI_SYMVERS"
[ -s "$GKI_SYMVERS" ] || fail "pinned GKI vmlinux.symvers is empty"
mapfile -t SYMVERS_FILES < <(find "$WORKSPACE/out/bazel" -type f -name Module.symvers -size +0c -print | sort -u)
[ "${#SYMVERS_FILES[@]}" -gt 0 ] || fail "no non-empty Module.symvers from this build"

python3 - "$MODULE" "$GKI_SYMVERS" "$REPORT_DIR/rtl8187-kmi-crc-audit.txt" "${SYMVERS_FILES[@]}" <<'PY'
import re, subprocess, sys
module, gki_path, report_path, *module_paths = sys.argv[1:]
def parse(path):
    out = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 2 and re.fullmatch(r"(?:0x)?[0-9a-fA-F]{8}", p[0]):
                crc = p[0].lower().removeprefix("0x")
                out.setdefault(p[1], set()).add(crc)
    return out

exports = parse(gki_path)
for path in module_paths:
    for symbol, crcs in parse(path).items():
        exports.setdefault(symbol, set()).update(crcs)

output = subprocess.check_output(["modprobe", "--show-modversions", module], text=True)
imports = []
for line in output.splitlines():
    p = line.split()
    if len(p) >= 2 and re.fullmatch(r"(?:0x)?[0-9a-fA-F]{8}", p[0]):
        imports.append((p[1], p[0].lower().removeprefix("0x")))

missing, ambiguous, mismatches = [], [], []
for symbol, expected in imports:
    found = exports.get(symbol)
    if not found:
        missing.append(symbol)
    elif len(found) != 1:
        ambiguous.append((symbol, ",".join(sorted(found))))
    elif expected not in found:
        mismatches.append((symbol, expected, next(iter(found))))

lines = [
    f"module={module}",
    f"pinned_GKI_build={gki_path}",
    f"Module.symvers_files={len(module_paths)}",
    f"imports_checked={len(imports)}",
    f"missing_symbols={len(missing)}",
    f"ambiguous_export_CRCS={len(ambiguous)}",
    f"CRC_mismatches={len(mismatches)}",
]
lines += [f"MISSING {x}" for x in missing]
lines += [f"AMBIGUOUS {n} CRCs={v}" for n,v in ambiguous]
lines += [f"CRC_MISMATCH {n} module={e} build={a}" for n,e,a in mismatches]
with open(report_path, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))
if not imports or missing or ambiguous or mismatches:
    raise SystemExit("ERROR: RTL8187 imported-symbol CRC audit failed")
PY

{
  echo "RTL8187 module: $MODULE"
  echo "SHA256: $(sha256sum "$MODULE" | awk '{print $1}')"
  echo "Kernel release/vermagic: $RELEASE"
  echo "USB alias 0BDA:8187: PASS"
  echo "Declared dependencies: $DEPENDS"
  echo "Same-tree mac80211 + EEPROM dependencies: PASS"
  echo "modules.dep direct dependency resolution: PASS"
  echo "No early-boot modules.load entry: PASS"
  echo "Pinned GKI + same-build Module.symvers CRC audit: PASS"
  echo "Strict Pixel KMI remains authoritative; no whitelist was widened."
} | tee "$REPORT_DIR/rtl8187-module-verification.txt"
