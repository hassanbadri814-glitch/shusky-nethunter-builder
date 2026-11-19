#!/usr/bin/env bash
# Inspect the actual ext4 DLKM images; do not infer image inclusion from module_outs.
set -Eeuo pipefail
IFS=$'\n\t'
VENDOR_IMAGE="${1:?vendor_dlkm.img required}"
SYSTEM_IMAGE="${2:?system_dlkm.img required}"
RTL_STAGED="${3:?staged rtl8187.ko required}"
EEPROM_STAGED="${4:?staged eeprom_93cx6.ko required}"
EXPECTED_RELEASE="${5:?expected kernel release required}"
REPORT_DIR="${6:?report directory required}"
mkdir -p "$REPORT_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FATAL: $*" >&2; exit 1; }

for image in "$VENDOR_IMAGE" "$SYSTEM_IMAGE"; do
  [ -s "$image" ] || fail "missing/empty DLKM image: $image"
  command -v debugfs >/dev/null || fail "debugfs (e2fsprogs) is required"
  debugfs -R stats "$image" >"$TMP/stats.txt" 2>&1 || fail "cannot read ext filesystem metadata from $image"
  grep -Eqi 'Filesystem magic number:[[:space:]]+0xEF53' "$TMP/stats.txt" || fail "$image is not a readable ext filesystem image"
done

debugfs -R "rdump / $TMP/vendor" "$VENDOR_IMAGE" >"$TMP/vendor-rdump.log" 2>&1 || fail "cannot extract vendor_dlkm filesystem"
debugfs -R "rdump / $TMP/system" "$SYSTEM_IMAGE" >"$TMP/system-rdump.log" 2>&1 || fail "cannot extract system_dlkm filesystem"

mapfile -t RTL_FILES < <(find "$TMP/vendor" "$TMP/system" -type f -name rtl8187.ko -print | sort)
mapfile -t EEPROM_FILES < <(find "$TMP/vendor" "$TMP/system" -type f -name eeprom_93cx6.ko -print | sort)
[ "${#RTL_FILES[@]}" -eq 1 ] || fail "expected exactly one rtl8187.ko inside combined DLKM images; found ${#RTL_FILES[@]}"
[ "${#EEPROM_FILES[@]}" -eq 1 ] || fail "expected exactly one eeprom_93cx6.ko inside combined DLKM images; found ${#EEPROM_FILES[@]}"

sha256sum -c <(printf '%s  %s\n' "$(sha256sum "$RTL_STAGED" | awk '{print $1}')" "${RTL_FILES[0]}") >/dev/null || fail "RTL8187 image copy differs from audited staged module"
sha256sum -c <(printf '%s  %s\n' "$(sha256sum "$EEPROM_STAGED" | awk '{print $1}')" "${EEPROM_FILES[0]}") >/dev/null || fail "EEPROM image copy differs from audited staged module"

for module in "${RTL_FILES[0]}" "${EEPROM_FILES[0]}"; do
  readelf -h "$module" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail "non-AArch64 module in DLKM image: $module"
  release="$(modinfo -F vermagic "$module" | awk '{print $1}')"
  [ "$release" = "$EXPECTED_RELEASE" ] || fail "DLKM module exact vermagic mismatch: $module ($release)"
done

RTL_ROOT="${RTL_FILES[0]%/kernel/drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko}"
EEPROM_ROOT="${EEPROM_FILES[0]%/kernel/drivers/misc/eeprom/eeprom_93cx6.ko}"
[ "$RTL_ROOT" = "$EEPROM_ROOT" ] || fail "RTL8187 and EEPROM modules are not in the same DLKM module tree"
[ -s "$RTL_ROOT/modules.dep" ] || fail "DLKM modules.dep missing"
[ -s "$RTL_ROOT/modules.alias" ] || fail "DLKM modules.alias missing"
DEP_LINE="$(grep -F 'rtl8187.ko:' "$RTL_ROOT/modules.dep" || true)"
[ -n "$DEP_LINE" ] || fail "DLKM modules.dep lacks RTL8187"
[[ "$DEP_LINE" == *mac80211.ko* ]] || fail "DLKM modules.dep does not resolve mac80211"
[[ "$DEP_LINE" == *eeprom_93cx6.ko* ]] || fail "DLKM modules.dep does not resolve eeprom_93cx6"
grep -Eiq 'usb:v0BDAp8187' "$RTL_ROOT/modules.alias" || fail "DLKM modules.alias lacks USB ID 0BDA:8187"
if [ -f "$RTL_ROOT/modules.load" ] && grep -Eq '(^|/)rtl8187\.ko|(^|/)eeprom_93cx6\.ko' "$RTL_ROOT/modules.load"; then
  fail "USB driver or EEPROM helper incorrectly autoloaded during early boot"
fi
if [ -f "$RTL_ROOT/modules.blocklist" ] && grep -Eiq '(^|[[:space:]])(rtl8187|eeprom_93cx6)([[:space:]]|$)' "$RTL_ROOT/modules.blocklist"; then
  fail "RTL8187 or EEPROM helper is blocklisted in DLKM"
fi

{
  echo "vendor_dlkm.img: $VENDOR_IMAGE"
  echo "system_dlkm.img: $SYSTEM_IMAGE"
  echo "RTL8187 image path: ${RTL_FILES[0]}"
  echo "EEPROM image path: ${EEPROM_FILES[0]}"
  echo "RTL8187 SHA256 matches staged build: PASS"
  echo "EEPROM SHA256 matches staged build: PASS"
  echo "AArch64 + exact vermagic: PASS"
  echo "Same DLKM module tree: PASS"
  echo "modules.dep direct dependencies: PASS"
  echo "modules.alias USB 0BDA:8187: PASS"
  echo "No early-boot autoload or blocklist: PASS"
} | tee "$REPORT_DIR/rtl8187-dlkm-image-verification.txt"
