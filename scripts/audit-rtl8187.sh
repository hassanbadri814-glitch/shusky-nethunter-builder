#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="${1:?workspace path required}"
EXPECTED_RELEASE="${2:?expected kernel release required}"
REPORT_DIR="${3:?report directory required}"
CONFIG="${4:?final kernel config path required}"
mkdir -p "$REPORT_DIR"

mapfile -t MODULES < <(
  find "$WORKSPACE/out/bazel" -type f \
    -path '*/staging/lib/modules/*/kernel/drivers/net/wireless/realtek/rtl8187/rtl8187.ko' \
    -print | sort -u
)
if [ "${#MODULES[@]}" -ne 1 ]; then
  printf 'ERROR: expected exactly one staged rtl8187.ko; found %s\n' "${#MODULES[@]}"
  printf '%s\n' "${MODULES[@]}"
  exit 1
fi

MODULE="${MODULES[0]}"
RELEASE="$(modinfo -F vermagic "$MODULE" | awk '{print $1}')"
RELEASE="${RELEASE%-ab*}"
if [ "$RELEASE" != "$EXPECTED_RELEASE" ]; then
  echo "ERROR: RTL8187 vermagic $RELEASE does not match $EXPECTED_RELEASE"
  exit 1
fi

DEPENDS="$(modinfo -F depends "$MODULE")"
case ",$DEPENDS," in
  *,mac80211,*) ;;
  *) echo "ERROR: RTL8187 does not declare its mac80211 dependency"; exit 1 ;;
esac
if ! grep -Eq '^CONFIG_EEPROM_93CX6=(m|y)$' "$CONFIG"; then
  echo "ERROR: EEPROM_93CX6 is not enabled in the final kernel config"
  exit 1
fi

MODULES_ROOT="${MODULE%%/kernel/drivers/net/wireless/realtek/rtl8187/rtl8187.ko}"
DEPFILE="$MODULES_ROOT/modules.dep"
if [ ! -f "$DEPFILE" ]; then
  echo "ERROR: matching modules.dep not found beside RTL8187 staging tree"
  exit 1
fi
DEP_LINE="$(grep -F 'kernel/drivers/net/wireless/realtek/rtl8187/rtl8187.ko:' "$DEPFILE" || true)"
if [ -z "$DEP_LINE" ]; then
  echo "ERROR: modules.dep has no RTL8187 dependency entry"
  exit 1
fi
if [[ "$DEPENDS" == *eeprom_93cx6* ]]; then
  if [[ "$DEP_LINE" != *eeprom_93cx6.ko* ]]; then
    echo "ERROR: modules.dep does not resolve the EEPROM module dependency"
    exit 1
  fi
  if [ ! -f "$MODULES_ROOT/kernel/drivers/misc/eeprom/eeprom_93cx6.ko" ] && \
     ! find "$WORKSPACE/out/bazel" -type f -name eeprom_93cx6.ko -print -quit | grep -q .; then
    echo "ERROR: eeprom_93cx6.ko is not present in any staged build output"
    exit 1
  fi
fi

if find "$WORKSPACE/out" -type f -name modules.load -exec grep -l 'rtl8187.ko' {} + | grep -q .; then
  echo "ERROR: RTL8187 was placed in early-boot modules.load; it must remain on-demand"
  exit 1
fi

mapfile -t SYMVERS < <(find "$WORKSPACE/out/bazel" -type f -name Module.symvers -print)
if [ "${#SYMVERS[@]}" -eq 0 ]; then
  echo "ERROR: no Module.symvers found for the RTL8187 CRC audit"
  exit 1
fi

python3 - "$MODULE" "$REPORT_DIR/rtl8187-kmi-crc-audit.txt" "${SYMVERS[@]}" <<'PY'
import subprocess, sys
module, report, *symvers_files = sys.argv[1:]
def norm(value):
    value = value.lower()
    return value[2:] if value.startswith("0x") else value

exports = {}
for path in symvers_files:
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) >= 2 and fields[0].startswith("0x"):
                exports.setdefault(fields[1], set()).add(norm(fields[0]))

output = subprocess.check_output(["modprobe", "--show-modversions", module], text=True)
imports = []
for line in output.splitlines():
    fields = line.split()
    if len(fields) >= 2 and fields[0].startswith("0x"):
        imports.append((fields[1], norm(fields[0])))

missing, mismatches = [], []
for symbol, crc in imports:
    available = exports.get(symbol, set())
    if not available:
        missing.append(symbol)
    elif crc not in available:
        mismatches.append((symbol, crc, ",".join(sorted(available))))

lines = [
    f"RTL8187 module: {module}",
    f"Module.symvers files scanned: {len(symvers_files)}",
    f"Imported symbols checked: {len(imports)}",
    f"Missing symbols: {len(missing)}",
    f"CRC mismatches: {len(mismatches)}",
]
lines.extend(f"MISSING {symbol}" for symbol in missing)
lines.extend(f"CRC_MISMATCH {symbol} module={crc} build={available}"
             for symbol, crc, available in mismatches)
with open(report, "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
print("\n".join(lines))
if not imports or missing or mismatches:
    raise SystemExit("ERROR: RTL8187 symbol CRC audit failed")
PY

{
  echo "RTL8187 module: $MODULE"
  echo "Kernel release/vermagic: $RELEASE"
  echo "Dependencies: $DEPENDS"
  echo "EEPROM_93CX6 config: enabled"
  echo "modules.dep dependency graph: PASS"
  echo "No early-boot modules.load entry: PASS"
  echo "Imported symbol CRC audit: PASS"
  echo "The Bazel/Kleaf strict Pixel KMI check remains authoritative; no KMI whitelist was expanded."
} | tee "$REPORT_DIR/rtl8187-module-verification.txt"
