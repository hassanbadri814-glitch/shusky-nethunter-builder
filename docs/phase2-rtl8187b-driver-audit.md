# Phase 2 — RTL8187 USB adapter integration

## Device identification

- Reported USB hardware ID: `USB\\VID_0BDA&PID_8187&REV_0200`
- VID:PID: `0bda:8187`
- Windows description: Realtek RTL8187B Wireless 802.11b/g USB 2.0
- Windows reports that the adapter works on the laptop.

The USB ID is a driver-match clue, not proof of the exact silicon revision or authenticity of the ALFA enclosure. Linux's in-tree RTL8187 driver supports RTL8187 and RTL8187B and contains the matching Realtek USB ID. The actual chip identity and driver binding must still be checked on the Pixel.

## Changes implemented on this branch

The integration is isolated to `phase2/rtl8187b-driver-audit`. The main branch and phone have not been changed.

1. Native FIPS defconfig fragment now requests `CONFIG_RTL8187=m and CONFIG_EEPROM_93CX6=m`.
2. Shusky `module_outs` integration adds:
   - `drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko`
   - `drivers/misc/eeprom/eeprom_93cx6.ko`
   - existing `crypto/fips140.ko` remains included.
3. The final merged kernel config must confirm `CONFIG_RTL8187=m` and `CONFIG_EEPROM_93CX6=m|y`; a fragment line alone is not accepted as proof.
4. The workflow keeps the strict Pixel KMI symbol list and the existing supplemental FIPS ABI list. It does not automatically widen the KMI whitelist for RTL8187.
5. Existing Native FIPS, UFS/FIPS module dependency, HMAC, KernelSU-inline-disabled and image-size checks remain in the build workflow.
6. A dedicated audit script checks the built module's AArch64 ELF type, exact kernel release/vermagic, EEPROM/mac80211 dependencies, generated `modules.dep`, absence from early-boot `modules.load`, and imported-symbol CRCs.
7. RTL8187 and EEPROM modules are packaged with the build outputs. The USB driver is intentionally not placed in the early boot ramdisk; it is to be loaded on demand.

## Build compatibility target

The workflow pins kernel/common commit `fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462`, expected release `6.1.145-android14-11-gfa1d6308d1fe`, and GKI build `14691759`. The new module must match that exact kernel build.

The Bazel/Kleaf strict Pixel KMI gate is authoritative. A symbol that is not part of the allowed KMI must cause the build to fail; this branch must not work around that failure by weakening the Pixel KMI list. The separate Module.symvers CRC audit is an additional compatibility check, not a replacement for the strict KMI gate.

## Test stages

**Stage A — build only:** verify configuration, compile and stage the modules, check KMI/CRC/dependencies, package DLKM images, and compare image sizes with the known Pixel 8 partition capacities. No phone flashing is performed by CI.

**Stage B — device validation, not yet authorized/performed:** after reviewing the build artifacts, plan a recovery-safe installation and test USB enumeration, driver binding, wireless interface, monitor mode and controlled injection on an authorized test network. The working Android/FIPS/KernelSU baseline remains untouched until a separate explicit flash decision.

## Current status

- Repository integration: implemented on this branch.
- Test build: pending.
- Build artifact: not yet produced.
- Pixel 8 USB/monitor/injection test: not yet performed.
- Phone flash or partition change: none.


## Fail-closed audit hardening

The audit now checks the real Linux source layout under `drivers/net/wireless/realtek/rtl818x/rtl8187` (not a guessed `rtl8187` parent directory), confirms the Kconfig EEPROM select and Makefile target, requires the final merged EEPROM module setting, checks the compiled USB alias for VID:PID 0BDA:8187, verifies the direct dependency files in each staging tree, and compares imported CRCs against the pinned GKI build plus the same build's Module.symvers. Conflicting CRC definitions are a hard failure.
