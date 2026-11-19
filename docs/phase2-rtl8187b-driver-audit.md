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
- Follow-up ABI/source compatibility route: implemented in the branch; the next CI run validates the exact pinned GKI ABI exports and both source-level substitutions.
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


## ABI preflight correction

The Android 6.1 Shusky branch maintains the GKI-wide additional KMI symbol-list aggregation in the root `BUILD.bazel` filegroup `aarch64_additional_kmi_symbol_lists`; `build.config.gki.aarch64` does not duplicate that list. The audit therefore checks the authoritative Bazel filegroup and verifies that `kernel_aarch64` consumes it, then checks the exact pinned GKI build's `vmlinux.symvers` for every required export. This avoids a false failure caused by checking the wrong configuration source while retaining the strict symbol/export gates.


## Exact GKI kernel-release stamping

The pinned GKI source commit is `fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462`, associated with GKI build `14691759`. The RTL8187 KMI compatibility patch intentionally modifies exactly three tracked source files in `kernel/common`, so Kleaf's local Git version calculation truthfully adds `-dirty`. The expected full release is therefore:

`6.1.145-android14-11-gfa1d6308d1fe-dirty-ab14691759`

The workflow does not conceal or normalize away `-dirty`. Its workspace-status wrapper checks the exact pinned Git commit, the exact three-file source delta, clean diff formatting, the Repo manifest and the official Kleaf status output. It requires the observed `aosp` SCM value to be exactly `-gfa1d6308d1fe-dirty-ab14691759`. A later audit must also prove that the kernel Image and every staged module carry the same complete release. The previous `workspace_status.json` override was ineffective with Kleaf's default localversion path and is no longer treated as authoritative.

## Kleaf SCM stamping and reusable build cache

Kleaf's default localversion calculation derives the source hash and dirty state directly from Git. A `workspace_status.json` SCMVERSION override did not affect the resulting module vermagic and must not be relied on for this build. The workflow now runs an explicit status wrapper before compilation and also supplies it as Bazel's `--workspace_status_command`. The wrapper exports the exact Repo manifest and GKI build number, validates the pinned source revision and permitted three-file patch, and passes Google's own status output through unchanged. The build fails before compilation if the observed SCM identity differs from the expected truthful dirty release.

The Bazel disk cache is restored with a versioned GKI/RTL8187 key and saved in a separate `actions/cache/save` step with `if: always()`. Completed Bazel actions can therefore be reused after a failed compile or audit. The Repo source cache remains separate and continues to retain the synchronized Google source objects.

## Whitespace regression caught by SCM preflight

Run `44442181765` correctly stopped before kernel compilation because removing the redundant RTL8187 rfkill wrapper left an extra blank line at EOF in `rfkill.c`. Google's source diff check rejected it. The KMI patch script now trims trailing whitespace from that edited file and writes exactly one final newline. The strict `git diff --check` remains enabled; the check itself is not weakened.
