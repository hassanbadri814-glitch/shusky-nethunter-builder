# Pixel 8 (shiba) NetHunter Native FIPS builder

This repository builds the Google Shusky/Zuma kernel distribution for the **Pixel 8 (shiba)**, using the Android 16 Shusky source manifest and the matching Google GKI 2.0 base.

## Build baseline

- Device: Pixel 8 `shiba` (Tensor G3 / Zuma)
- Android baseline: Android 16, SDK 36
- GKI family: `android14-6.1`
- Target GKI build: `14691759`
- Exact `kernel/common` source commit: `fa1d6308d1fe803c3fdebcd3ee6f7a1155fc3462`
- Kernel release prefix: `6.1.145-android14-11-gfa1d6308d1fe`
- Native FIPS: in-tree `fips140.ko`, HMAC post-link verification, Pixel KMI plus FIPS ABI checks
- KernelSU Inline: deliberately disabled (`CONFIG_KSU` unset)

The GKI kernel image and all vendor modules must be built against the same kernel source revision/KMI. A successful CI job is not sufficient by itself: the produced module release and symbol CRCs must also be audited against the selected GKI base.

## KernelSU-Next

KernelSU-Next is **not compiled into this kernel** and is not added to `vendor_kernel_boot` or the DLKM images.

For this Pixel 8 GKI 2.0 device, KernelSU-Next LKM is a separate installation step managed by the KernelSU-Next app. It uses the matching `android14-6.1` LKM and patches the device's `init_boot` image. Keep the kernel build and LKM installation separate; do not enable KernelSU Inline just to restore LKM root.

The build workflow does not patch or flash `init_boot`, and it never flashes the phone.

## Safety

- The workflow only builds and packages images; it does not flash any device.
- Preserve the exact stock images for the active firmware before any manual flash.
- Do not flash an artifact unless its kernel release, module compatibility, partition sizes, and independent audit have passed.
- A green GitHub build is not proof that Android boots. Runtime boot and FIPS status still require device-side verification.
