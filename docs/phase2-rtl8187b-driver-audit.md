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
4. The workflow keeps the strict Pixel KMI base and the supplemental FIPS ABI. For RTL8187, it may reference Google's already-published `abi_gki_aarch64_virtual_device` list only after the exact pinned GKI source and GKI build's `vmlinux.symvers` prove that every required symbol is already part of that official GKI ABI/export set. No ad-hoc symbols are added, no Pixel ABI file is edited, and strict KMI enforcement remains enabled.
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
- First strict CI run `44427195189`: rejected by the Pixel KMI gate; no build artifact was accepted.
- Follow-up ABI/source compatibility route: implemented in the branch; awaiting the next CI result.
- Build artifact: not yet produced.
- Pixel 8 USB/monitor/injection test: not yet performed.
- Phone flash or partition change: none.


## Fail-closed audit hardening

The audit now checks the real Linux source layout under `drivers/net/wireless/realtek/rtl818x/rtl8187` (not a guessed `rtl8187` parent directory), confirms the Kconfig EEPROM select and Makefile target, requires the final merged EEPROM module setting, checks the compiled USB alias for VID:PID 0BDA:8187, verifies the direct dependency files in each staging tree, and compares imported CRCs against the pinned GKI build plus the same build's Module.symvers. Conflicting CRC definitions are a hard failure.


## First test-build failure and correction

The first CI test build did not reach compilation. Kleaf's config validator rejected `CONFIG_RTL8187=m` because the symbol resolved to an empty value in the merged config. The GKI baseline disables the Realtek vendor Kconfig menu by default, so the driver symbol must not be requested without enabling its parent menu. The branch now explicitly enables `CONFIG_WLAN_VENDOR_REALTEK=y`, checks the parent Kconfig source chain, and requires that setting in the final merged `.config`. This is a configuration prerequisite, not a reason to weaken KMI checks.

The first run used the earlier, incorrect module output path. The corrected path is `drivers/net/wireless/realtek/rtl818x/rtl8187/rtl8187.ko`. The workflow preflight now rejects the old path and checks Bash script syntax plus workflow YAML before spending time on a kernel build.

Final image validation is fail-closed: the audit extracts both ext4 DLKM images, proves the RTL8187 and EEPROM module bytes are present in the image and identical to the audited staged files, verifies same-tree dependency metadata, USB alias, exact vermagic, and rejects early-boot autoload or blocklisting. Required artifacts may not be missing during packaging or upload.


## Strict verification run

A new isolated CI run is authorized after the Realtek parent-menu correction and fail-closed audit changes. This run must pass the source/Kconfig preflight, merged-config checks, exact module output and dependency audits, strict Pixel KMI, pinned GKI CRC checks, FIPS/UFS load-order checks, ext4 DLKM image extraction and module hash comparison, partition-capacity checks, and verified artifact packaging. A failure at any gate rejects the artifact. No phone flashing is part of this workflow.


## Second KMI investigation — targeted compatibility route

The first real RTL8187 build reached the strict KMI gate and identified 12 imports outside the Shusky Pixel+FIPS symbol-list union. The driver itself compiled; the artifact was correctly rejected.

The follow-up route is deliberately narrow:

- Ten of the imports are USB/network-core symbols listed in Google's published `abi_gki_aarch64_virtual_device` ABI. The workflow now checks that this exact ABI file is part of the pinned GKI source build and that all ten symbols are actually exported by GKI build 14691759's `vmlinux.symvers` before compilation. Only then is that existing upstream ABI list referenced as an additional list; no symbol is manually appended.
- The driver's two remaining imports are removed at source level. The two `skb_unlink()` sites are replaced with the equivalent in-header `__skb_unlink()` operation while taking the same queue spinlock used by `skb_unlink()`. The redundant RTL8187 rfkill stop wrapper is removed because `ieee80211_unregister_hw()` calls `wiphy_unregister()`, which unregisters rfkill and cancels its polling work. The patch script verifies these lifecycle calls in the pinned source before changing files.
- The source patch is exact-match and fail-closed: if expected source context differs, the workflow stops rather than applying a partial or guessed patch.
- The post-build module audit rejects any remaining `skb_unlink` or `rfkill_pause_polling` import. The strict Kleaf KMI gate and GKI CRC checks remain mandatory.

This is a testable compatibility hypothesis, not yet a proven result. The next CI run must prove the official ABI/export set and pass the unchanged strict KMI gate. No phone flashing is performed.
