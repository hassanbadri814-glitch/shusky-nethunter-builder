# Phase 2 — RTL8187 USB adapter audit

Status: source/configuration investigation only. No kernel build, device change, flash, or merge has been performed.

## Device evidence supplied by the user

- Windows hardware ID: `USB\\VID_0BDA&PID_8187&REV_0200`
- USB VID:PID: `0bda:8187`
- Windows description: `Realtek RTL8187B Wireless 802.11b/g USB 2.0`
- Adapter reportedly works on the Windows laptop.

The USB ID is useful for driver matching, but does not uniquely identify the silicon revision or prove that the physical adapter is an authentic ALFA AWUS036H. Windows `REV_0200` is the USB descriptor revision, not a verified RTL8187 silicon revision.

## Confirmed kernel-driver facts

1. Linux mainline has an in-tree `rtl8187` mac80211 USB driver explicitly described as supporting RTL8187 and RTL8187B.
2. Its USB ID table includes Realtek `0x0bda:0x8187`, matching the user's reported VID:PID.
3. The kernel wireless Kconfig entry defines `CONFIG_RTL8187` as a tristate and requires `MAC80211 && USB && WLAN_80211`; it selects `EEPROM_93CX6`.
4. The current builder already enables `CONFIG_USB=y`, `CONFIG_CFG80211=m`, and `CONFIG_MAC80211=m`, but does not enable `CONFIG_RTL8187`.
5. The current workflow explicitly fails if any `rtl8187*.ko` is found. This is an intentional build exclusion, not evidence that the adapter or Pixel USB host is defective.

## Important hardware-identification nuance

ALFA's official AWUS036H documentation identifies the original AWUS036H as RTL8187L with VID:PID `0bda:8187`. Linux Wireless device documentation also lists a different RTL8187B-based product using the same VID:PID. Therefore, the user's Windows label and USB ID do not settle L-versus-B silicon identity. The in-kernel driver supports both families, but the actual adapter must be checked after driver binding.

## Required build integration — not yet applied

- Enable `CONFIG_RTL8187=m` in the Shusky config fragment.
- Verify the final merged `.config` actually contains `CONFIG_RTL8187=m`; a fragment line alone is not proof because unmet Kconfig dependencies can silently disable it.
- Confirm `CONFIG_EEPROM_93CX6` is selected and determine whether `eeprom_93cx6.ko` comes from the exact GKI prebuilt or must be included in the Shusky module outputs.
- Add the in-tree `rtl8187.ko` output to the device module output set only after confirming the exact path in the pinned source checkout.
- Do not place this USB peripheral driver in the early-boot vendor ramdisk list. It should be staged in the appropriate Android DLKM module set and loaded on demand after USB enumeration.
- Ensure the generated `modules.dep` resolves every dependency; do not rely on a manually guessed load order.
- Preserve the existing Native FIPS early-boot ordering and UFS/FIPS module dependency checks unchanged.
- Preserve `CONFIG_KSU` disabled in the kernel; KernelSU-Next remains the existing LKM setup.

## KMI / module compatibility gates

The builder pins kernel/common commit `fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462` and GKI build `14691759`, with expected release `6.1.145-android14-11-gfa1d6308d1fe`. The RTL8187 module must be built from this exact source/configuration and match that release.

Before any phone installation, the CI audit must verify:

- final `.config`: RTL8187 is `m`; USB, MAC80211, and WLAN prerequisites are satisfied;
- `rtl8187.ko` exists in the final staged module set and has the expected AArch64 ELF type;
- `vermagic` matches the exact pinned kernel release;
- `modinfo -F depends` and generated `modules.dep` show all required dependencies, including EEPROM support where modular;
- every imported symbol is available from the matching GKI `vmlinux.symvers` with matching CRC, including `module_layout`;
- strict Pixel KMI and supplemental ABI handling are respected; if new symbols are required, generate and review the module symbol list rather than weakening strict KMI;
- the final DLKM image fits the user's measured Pixel 8 partition capacity;
- Native FIPS module hashes/HMAC, UFS FIPS dependencies, and existing KernelSU exclusions remain unchanged.

## Runtime test gates — not yet performed

1. Confirm USB OTG enumerates `0bda:8187` on the Pixel.
2. Load the matching driver and confirm a wireless interface appears; capture kernel logs and module state.
3. Confirm monitor mode and supported channels.
4. Perform a controlled packet-injection test on an isolated, authorized test network.
5. Verify normal Android boot, Native FIPS module presence, and KernelSU-Next root remain intact after the test.

A successful build is not a successful device test. No flash should be considered until all static/build gates pass and a recovery-safe installation plan is reviewed.

## Current conclusion

The user's adapter has a strong Linux-driver match based on `0bda:8187`, and the repository's explicit RTL8187 exclusion explains why the present kernel cannot provide this driver. The next engineering step is exact Kconfig/module/KMI integration and CI verification against the pinned Pixel 8 kernel—not installing a random external driver or changing the working phone.
