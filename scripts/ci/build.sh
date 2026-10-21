#!/usr/bin/env bash
set -euo pipefail

FLAVOR="${1:-radium-monitor}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PATCHED_MODULES_REPO="https://github.com/Raju-yeager/android_kernel_xiaomi_sm8635-modules.git"
ANYKERNEL_REPO="https://github.com/osm0sis/AnyKernel3.git"

CLANG_DIR="${CLANG_DIR:?CLANG_DIR must point to Clang root}"
export PATH="$CLANG_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-Raju-yeager}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Radium}"

OUT="${OUT_DIR:-$ROOT/out}"
DIST="${DIST_DIR:-$ROOT/dist}"
JOBS="${JOBS:-$(nproc --all)}"
ZIP_PREFIX="${ZIP_PREFIX:-Radium-Monitor}"
ZIP_VERSION="${ZIP_VERSION:-v1.0}"

WARN_FLAGS="-Wno-error -Wno-gnu-zero-variadic-macro-arguments -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable -Wno-misleading-indentation -Wno-format ${KCFLAGS:-}"

log() {
  printf '\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"
}

log "flavor=$FLAVOR  clang:$(clang --version | head -1)"
log "Building directly from kernel source: $(head -n 4 "$ROOT/Makefile" | tr '\n' ' ')"

# 1. Fix OpenSSL 3.0 undeclared 'key_pass' on Ubuntu 24.04 runners
if [[ -f "$ROOT/certs/extract-cert.c" ]]; then
  sed -i '/static.*key_pass/d' "$ROOT/certs/extract-cert.c"
  sed -i '1i __attribute__((unused)) static const char *key_pass;' "$ROOT/certs/extract-cert.c"
fi

rm -rf "$OUT" "$DIST"
mkdir -p "$OUT" "$DIST"

# 2. Generate Base Defconfig
log "Generating base gki_defconfig..."
make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 gki_defconfig

for frag in \
  "$ROOT/arch/arm64/configs/vendor/pineapple_GKI.config" \
  "$ROOT/arch/arm64/configs/vendor/peridot_GKI.config" \
  "$ROOT/arch/arm64/configs/peridot_GKI.config"; do
  if [[ -f "$frag" ]]; then
    log "Merging fragment: $frag"
    ARCH=arm64 "$ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$frag"
  fi
done

log "Applying Vibranium config + ThinLTO + Wireless Monitor dependencies..."
./scripts/config --file "$OUT/.config" \
  --set-str LOCALVERSION "-Radium-Monitor" \
  -d LOCALVERSION_AUTO \
  -d WERROR \
  --set-val UCLAMP_BUCKETS_COUNT 20 \
  -d TASK_DELAY_ACCT \
  -d CFS_BANDWIDTH \
  -d RT_GROUP_SCHED \
  -d CGROUP_PIDS \
  -d CGROUP_DEVICE \
  -d CGROUP_PERF \
  -d CGROUP_MISC \
  -d USER_NS \
  -d RSEQ \
  -d SCHED_CLUSTER \
  -e SCHED_MC \
  -e SCHED_HRTICK \
  -e RT_SOFTIRQ_AWARE_SCHED \
  -e RCU_BOOST \
  -e RCU_LAZY \
  -e RCU_LAZY_DEFAULT_OFF \
  -e BOEFFLA_WL_BLOCKER \
  -e UNWIND_TABLES \
  -e UNWIND_PATCH_PAC_INTO_SCS \
  -e DYNAMIC_SCS \
  -d HZ_100 \
  -e HZ_250 \
  -d HZ_300 \
  -d HZ_1000 \
  --set-val HZ 250 \
  -d LTO_NONE \
  -d LTO_CLANG_FULL \
  -e LTO \
  -e LTO_CLANG \
  -e LTO_CLANG_THIN \
  -e CFI_CLANG \
  -d MODULE_SIG_ALL \
  -e MODULE_SIG_SHA256 \
  -d MODULE_SIG_SHA512 \
  --set-str MODULE_SIG_HASH "sha256" \
  -m MI_HARDWARE_ID \
  -m RFKILL \
  -m CFG80211 \
  -e NL80211_TESTMODE \
  -e CFG80211_REQUIRE_SIGNED_REGDB \
  -e CFG80211_USE_KERNEL_REGDB_KEYS \
  -e CFG80211_DEFAULT_PS \
  -d CFG80211_CRDA_SUPPORT \
  -d CFG80211_WEXT \
  -m MAC80211

make O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig

# 3. Build Kernel Image & In-Tree Modules
log "Building Kernel Image & Modules (jobs=$JOBS)"
if ! make -j"$JOBS" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="ccache clang" HOSTCC="ccache clang" HOSTCXX="ccache clang++" \
  KBUILD_MODPOST_WARN=1 \
  KCFLAGS="$WARN_FLAGS" \
  Image modules 2>&1 | tee "$OUT/build.log"; then
  echo "::error::Kernel build failed! Printing compiler/linker errors from build.log:"
  grep -n -C 5 -E "(error:|fatal error:|undefined symbol|ld\.lld: error:)" "$OUT/build.log" || true
  exit 1
fi

IMG="$OUT/arch/arm64/boot/Image"
if [[ ! -f "$IMG" ]]; then
  echo "::error::Kernel Image was not produced at $IMG"
  exit 1
fi

cp -f "$IMG" "$DIST/Image-$FLAVOR"
cp -f "$OUT/Module.symvers" "$DIST/Module.symvers-$FLAVOR"
cp -f "$OUT/.config" "$DIST/config-$FLAVOR"

# 4. Clone Pre-Patched WLAN Driver Repo & Build qca_cld3_qca6750.ko
log "Cloning pre-patched SM8635 modules from $PATCHED_MODULES_REPO..."
rm -rf "$ROOT/modules_src"
git clone --depth=1 "$PATCHED_MODULES_REPO" "$ROOT/modules_src"

WLAN_DIR="$ROOT/modules_src/qcom/opensource/wlan"
QCACLD_DIR="$WLAN_DIR/qcacld-3.0"
ln -sfn ../qca-wifi-host-cmn "$QCACLD_DIR/cmn"

# Append 43 vendor_dlkm symbol CRCs so out-of-tree modpost succeeds
python3 - "$OUT/Module.symvers" << 'PYEOF'
import sys

symvers_path = sys.argv[1]
lines = open(symvers_path, "r", encoding="utf-8", errors="ignore").read().splitlines()
sample = lines[0] if lines else "0x00000000\tdummy\tvmlinux\tEXPORT_SYMBOL\t"
num_tabs = sample.count("\t")

vendor_syms = [
    ("0xf35b1593", "__icnss_register_driver"),
    ("0x62f5d9f4", "cld80211_get_genl_family"),
    ("0x7f3db83b", "cnss_utils_get_wlan_derived_mac_address"),
    ("0xdd04312a", "cnss_utils_get_wlan_mac_address"),
    ("0x7cab32df", "cnss_utils_get_wlan_unsafe_channel"),
    ("0x0e39f21c", "cnss_utils_increment_driver_load_cnt"),
    ("0x83d6fb88", "cnss_utils_set_wlan_unsafe_channel"),
    ("0xef048766", "cnss_utils_wlan_get_dfs_nol"),
    ("0xb83d7182", "cnss_utils_wlan_set_dfs_nol"),
    ("0x1a4d338d", "deregister_cld_cmd_cb"),
    ("0xd42566f2", "icnss_allow_l1"),
    ("0x8831b37b", "icnss_athdiag_read"),
    ("0xaabf5c45", "icnss_athdiag_write"),
    ("0x61e3742e", "icnss_exit_power_save"),
    ("0xe32d9f2a", "icnss_force_wake_release"),
    ("0x0f936194", "icnss_force_wake_request"),
    ("0xc7db251a", "icnss_get_curr_therm_cdev_state"),
    ("0x71358fe3", "icnss_get_mhi_state"),
    ("0xd9cebef2", "icnss_get_msi_address"),
    ("0x22af7d88", "icnss_get_msi_irq"),
    ("0xf7f0c22c", "icnss_get_soc_info"),
    ("0xa8b17f5a", "icnss_get_user_msi_assignment"),
    ("0x71e6e153", "icnss_idle_restart"),
    ("0x413458df", "icnss_idle_shutdown"),
    ("0x354028de", "icnss_is_device_awake"),
    ("0x9b5bd3f7", "icnss_is_fw_down"),
    ("0xbadde3d4", "icnss_is_pci_ep_awake"),
    ("0x49e4b3b1", "icnss_power_off"),
    ("0x8f973526", "icnss_power_on"),
    ("0xa35f4a41", "icnss_prevent_l1"),
    ("0x6a21d2a9", "icnss_qmi_send"),
    ("0xb8aa15ba", "icnss_set_fw_log_mode"),
    ("0x46d9e785", "icnss_smmu_get_domain"),
    ("0x3c92e266", "icnss_smmu_map"),
    ("0xb71bf2a4", "icnss_thermal_cdev_register"),
    ("0x188e10cc", "icnss_thermal_cdev_unregister"),
    ("0x835eac09", "icnss_trigger_recovery"),
    ("0x07cf14dc", "icnss_unregister_driver"),
    ("0x254b144e", "icnss_wlan_disable"),
    ("0x10b1edcc", "icnss_wlan_enable"),
    ("0x14d2e4b6", "register_cld_cmd_cb"),
    ("0xdff15e8a", "wcnss_prealloc_get"),
    ("0x0521fc53", "wcnss_prealloc_put"),
]

existing = {l.split("\t")[1] for l in lines if "\t" in l}
with open(symvers_path, "a", encoding="utf-8") as f:
    for crc, name in vendor_syms:
        if name not in existing:
            extra_tabs = "\t" * max(0, num_tabs - 3)
            f.write(f"{crc}\t{name}\tvmlinux\tEXPORT_SYMBOL{extra_tabs}\n")
print(f"[+] Appended {len(vendor_syms)} vendor symbols")
PYEOF

if ! make -j"$JOBS" -C "$ROOT" O="$OUT" \
  M="$QCACLD_DIR" \
  CC="ccache clang" HOSTCC="ccache clang" HOSTCXX="ccache clang++" \
  WLAN_ROOT="$QCACLD_DIR" \
  WLAN_COMMON_ROOT=cmn \
  WLAN_COMMON_INC="$QCACLD_DIR/cmn" \
  WLAN_FW_API="$WLAN_DIR/fw-api/" \
  CONFIG_ARCH_PINEAPPLE=y \
  CONFIG_ARCH_QCOM=y \
  CONFIG_CNSS_OUT_OF_TREE=y \
  CONFIG_IPA_OUT_OF_TREE=y \
  CONFIG_QCA_WIFI_ISOC=0 \
  CONFIG_QCA_WIFI_2_0=1 \
  WLAN_PROFILE=qca6750 \
  CONFIG_QCA_CLD_WLAN_PROFILE=qca6750 \
  DYNAMIC_SINGLE_CHIP=qca6750 \
  DEVNAME=qca6750 \
  MODNAME=qca_cld3_qca6750 \
  CONFIG_QCA_CLD_WLAN=m \
  KBUILD_MODPOST_WARN=1 \
  KCFLAGS="$WARN_FLAGS" \
  modules 2>&1 | tee "$OUT/wlan_build.log"; then
  echo "::error::WLAN module build failed! Printing errors from wlan_build.log:"
  grep -n -C 5 -E "(error:|fatal error:|undefined symbol|ld\.lld: error:|Stop\.)" "$OUT/wlan_build.log" || true
  exit 1
fi

llvm-strip --strip-debug "$QCACLD_DIR/qca_cld3_qca6750.ko"

# 5. Package Unified AnyKernel3 Zip
STAGE="$(mktemp -d)"
git clone --depth=1 "$ANYKERNEL_REPO" "$STAGE"
rm -rf "$STAGE/.git"
sed -i 's/device.name1=.*/device.name1=peridot/g' "$STAGE/anykernel.sh"
sed -i 's/device.name2=.*/device.name2=pineapple/g' "$STAGE/anykernel.sh"
sed -i 's/BLOCK=.*/BLOCK=auto;/g' "$STAGE/anykernel.sh"
sed -i 's/IS_SLOT_DEVICE=.*/IS_SLOT_DEVICE=1;/g' "$STAGE/anykernel.sh"

cp -f "$IMG" "$STAGE/Image"
if [[ -f "$QCACLD_DIR/qca_cld3_qca6750.ko" ]]; then
  cp -f "$QCACLD_DIR/qca_cld3_qca6750.ko" "$STAGE/qca_cld3_qca6750.ko"
fi

STAMP="$(date -u +%Y%m%d)"
SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo local)"
ZIP_NAME="${ZIP_PREFIX}-${FLAVOR}-${ZIP_VERSION}-${STAMP}-${SHA}.zip"
(cd "$STAGE" && zip -r9q "$DIST/$ZIP_NAME" .)
rm -rf "$STAGE"
log "Packaged unified flashable zip: $DIST/$ZIP_NAME"

# 6. Build Universal Magisk/KernelSU Module
if [[ -f "$QCACLD_DIR/qca_cld3_qca6750.ko" ]]; then
  log "Packaging Universal Magisk/KernelSU Module..."
  MAGISK_DIR="$(mktemp -d)"
  mkdir -p "$MAGISK_DIR/META-INF/com/google/android"
  mkdir -p "$MAGISK_DIR/system/bin"

  curl -sL -o "$MAGISK_DIR/META-INF/com/google/android/update-binary" "https://raw.githubusercontent.com/topjohnwu/Magisk/master/scripts/module_installer.sh"
  chmod +x "$MAGISK_DIR/META-INF/com/google/android/update-binary"
  echo "#MAGISK" > "$MAGISK_DIR/META-INF/com/google/android/updater-script"

  cat << 'EOF' > "$MAGISK_DIR/module.prop"
id=eviltwin-wifi
name=Universal QCA6750 Monitor Mode Wi-Fi
version=v1.0
versionCode=1
author=Raju-yeager
description=Direct monitor mode for POCO F6 (peridot) ported from Loukious onyx-v-oss-monitor-direct. Adapts to ANY kernel at boot.
EOF

  cat << 'EOF' > "$MAGISK_DIR/customize.sh"
ui_print "- Installing Universal QCA6750 Monitor Mode Wi-Fi"
ui_print "- Automatically patches vermagic on boot to match your active kernel."
EOF

  cp "$QCACLD_DIR/qca_cld3_qca6750.ko" "$MAGISK_DIR/qca_cld3_qca6750_original.ko"

  cat << 'EOF' > "$MAGISK_DIR/post-fs-data.sh"
#!/system/bin/sh
MODDIR=${0%/*}
KO_FILE="$MODDIR/qca_cld3_qca6750.ko"
ORIG_FILE="$MODDIR/qca_cld3_qca6750_original.ko"
KVER="$(uname -r)"

if [ ! -f "$KO_FILE" ] || ! grep -q "vermagic=$KVER " "$KO_FILE"; then
    cp "$ORIG_FILE" "$KO_FILE"
    OFFSET=$(grep -aob "vermagic=" "$KO_FILE" | head -n 1 | cut -d: -f1)
    if [ -n "$OFFSET" ]; then
        printf "vermagic=%s SMP preempt mod_unload modversions aarch64\0" "$KVER" > "$MODDIR/new_vermagic"
        dd if="$MODDIR/new_vermagic" of="$KO_FILE" bs=1 seek="$OFFSET" conv=notrunc status=none
        rm -f "$MODDIR/new_vermagic"
    fi
fi
EOF
  chmod +x "$MAGISK_DIR/post-fs-data.sh"

  cat << 'EOF' > "$MAGISK_DIR/system/bin/wlan-mode"
#!/system/bin/sh
MODDIR="/data/adb/modules/eviltwin-wifi"
STOCK_KO=$(find /vendor_dlkm /vendor /system -type f -name qca_cld3_qca6750.ko | head -n 1)
MOD_KO="$MODDIR/qca_cld3_qca6750.ko"

if [ "$1" = "mon" ]; then
    echo "[+] Enabling Monitor Mode..."
    svc wifi disable
    ip link set wlan0 down
    rmmod qca_cld3_qca6750 2>/dev/null
    mount --bind "$MOD_KO" "$STOCK_KO"
    insmod "$STOCK_KO"
    iw dev wlan0 set type monitor 2>/dev/null || echo 4 > /sys/module/qca_cld3_qca6750/parameters/con_mode
    ip link set wlan0 up
    [ -n "$2" ] && iw dev wlan0 set channel "$2"
    echo "[+] wlan0 is now in Monitor Mode"
elif [ "$1" = "sta" ]; then
    echo "[+] Restoring Normal Android Wi-Fi..."
    ip link set wlan0 down
    umount "$STOCK_KO" 2>/dev/null
    rmmod qca_cld3_qca6750 2>/dev/null
    insmod "$STOCK_KO"
    echo 0 > /sys/module/qca_cld3_qca6750/parameters/con_mode 2>/dev/null
    svc wifi enable
    echo "[+] Normal Android Wi-Fi restored."
else
    echo "Usage: su -c wlan-mode [mon <channel> | sta]"
fi
EOF
  chmod +x "$MAGISK_DIR/system/bin/wlan-mode"

  (cd "$MAGISK_DIR" && zip -r9q "$DIST/Universal-EvilTwin-WiFi-Magisk-${ZIP_VERSION}.zip" .)
  rm -rf "$MAGISK_DIR"
  log "Packaged Universal Magisk Module: $DIST/Universal-EvilTwin-WiFi-Magisk-${ZIP_VERSION}.zip"
fi
