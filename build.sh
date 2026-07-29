#!/usr/bin/env bash
#
# Rey's GKI Kernel Builder
#

set -euo pipefail

# Paths
WORKDIR="$(pwd)"
OUTDIR="$WORKDIR/out"
GKI_DIR="$WORKDIR/gki"
KSRC="$GKI_DIR/common"
KERNEL_PATCHES="$WORKDIR/patch"
KERNEL_NAME="${KERNEL_NAME:-Kinosaki}"

# Identity
KBUILD_BUILD_USER="rey"
KBUILD_BUILD_HOST="ivy"
TIMEZONE="Asia/Jakarta"

# Build Defaults
KERNEL_DEFCONFIG="gki_defconfig"
ANYKERNEL_REPO="https://github.com/rinnsakaguchi/AnyKernel3"
ANYKERNEL_BRANCH="master"
GKI_RELEASES_REPO="Cartethyiaaa/builder"
BUILD_START=$(date +%s)

source "$WORKDIR/functions.sh"

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[0m'

info()    { echo -e "${B}[INFO]${W}  $*"; }
success() { echo -e "${G}[OK]${W}    $*"; }
warn()    { echo -e "${Y}[WARN]${W}  $*"; }
die()     { echo -e "${R}[ERR]${W}   $*" >&2; exit 1; }

trap 'die "Failed at line $LINENO [$BASH_COMMAND]"' ERR

exec > >(tee "$WORKDIR/build.log") 2>&1

# Timezone
sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null || export TZ="$TIMEZONE"

# Validate Required Env
for var in REPONYA GKIVER CLANGURL VARIANT CONFIGHZ TCPCONG LTOBUILD; do
    [[ -n "${!var:-}" ]] || die "Required env var \$$var is not set"
done

# GKI Manifest Version
case "$GKIVER" in
    5.10)
        MANIFEST_BRANCH="common-android12-5.10"
        ;;
    6.12)
        MANIFEST_BRANCH="common-android16-6.12"
        ;;
    *)
        die "Invalid GKIVER: $GKIVER (valid: 5.10 | 6.12)"
        ;;
esac

# Init Sync
info "Initializing and Syncing GKI Android $GKIVER Source Tree..."
mkdir -p "$GKI_DIR" && cd "$GKI_DIR"

repo init -u https://android.googlesource.com/kernel/manifest -b "$MANIFEST_BRANCH" --depth=1
repo sync -c --no-tags --no-clone-bundle --optimized-fetch --prune "-j$(nproc --all)"

cd "$WORKDIR"
success "GKI manifest sync complete."

cd "$KSRC"

case "$REPONYA" in
    main)
        REMOTE_NAME="Cartethyiaaa"
        case "$GKIVER" in
            5.10)
                KERNEL_REPO="https://github.com/Cartethyiaaa/android_kernel_common-5.10.git"
                KERNEL_BRANCH="${KERNELBRANCH:-android12-5.10}"
                ;;
            6.12)
                KERNEL_REPO="https://github.com/Cartethyiaaa/android_kernel_common-6.12.git"
                KERNEL_BRANCH="${KERNELBRANCH:-android16-6.12}"
                ;;
        esac
        ;;
    rama)
        [[ "$GKIVER" == "5.10" ]] || die "REPONYA=rama only has a 5.10 tree available"
        REMOTE_NAME="Anisphia"
        KERNEL_REPO="https://github.com/ramabondanp/android_kernel_common-5.10.git"
        KERNEL_BRANCH="android12-5.10-staging"
        ;;
    *)
        die "Invalid REPONYA: $REPONYA (valid: main | rama)"
        ;;
esac

info "Updating kernel source using $REMOTE_NAME ($KERNEL_BRANCH)..."

if ! git remote | grep -q "^${REMOTE_NAME}$"; then
    git remote add "$REMOTE_NAME" "$KERNEL_REPO"
fi

git fetch "-j$(nproc --all)" "$REMOTE_NAME"
git checkout -B "update-${KERNEL_BRANCH}" "${REMOTE_NAME}/${KERNEL_BRANCH}"

success "Kernel tree updated to ${REMOTE_NAME}/${KERNEL_BRANCH}"

# Return to WORKDIR for toolchain setup
cd "$WORKDIR"

# TOOLCHAIN SETUP (CLANG)
case "$CLANGURL" in
    12)   CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/06a71ddac05c22edb2d10b590e1769b3f8619bef/clang-r416183b.tar.gz" ;;
    22)   CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/af3fae2c8e67673c43217d0cf75dbf3f268de272/clang-r596125.tar.gz" ;;
    neutron) ;;
    *)    die "Invalid CLANGURL: $CLANGURL" ;;
esac

CLANG_DIR="$WORKDIR/clang"
CLANG_CACHE_DIR="${CLANG_CACHE_DIR:-$HOME/.cache/gki-clang}"

setup_google_clang() {
    local cache_key="$CLANG_CACHE_DIR/${CLANGURL}-$(basename "$CLANG_URL")"

    if [[ -d "$cache_key" && -x "$cache_key/bin/clang" ]]; then
        info "Using cached Clang ($CLANGURL) from $cache_key"
        mkdir -p "$CLANG_DIR"
        cp -r "$cache_key"/. "$CLANG_DIR"/
        return 0
    fi

    info "Downloading Google Clang ($CLANGURL)..."
    mkdir -p "$CLANG_DIR"
    aria2c -x16 -s16 -k1M --retry-wait=3 --max-tries=5 --summary-interval=0 \
        "$CLANG_URL" -o clang-archive || die "Clang download failed"

    case "$(basename "$CLANG_URL")" in
        *.tar.*|*.tgz) tar -xf clang-archive -C "$CLANG_DIR" ;;
        *.7z)          7z x clang-archive -o"${CLANG_DIR}/" -bd -y >/dev/null ;;
        *)             die "Unsupported clang archive format" ;;
    esac
    rm -f clang-archive

    # Flatten nested dir if present
    local subdirs
    subdirs=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
    local files
    files=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l)
    if [[ $subdirs -eq 1 && $files -eq 0 ]]; then
        local single
        single=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
        mv "$single"/* "$CLANG_DIR"/
        rm -rf "$single"
    fi

    # Populate cache for next run
    mkdir -p "$cache_key"
    cp -r "$CLANG_DIR"/. "$cache_key"/ 2>/dev/null || warn "Could not populate clang cache"
}

if [[ "$CLANGURL" != "neutron" ]]; then
    setup_google_clang
else
    info "Using Neutron Clang (antman)..."
    mkdir -p "$CLANG_DIR"
    pushd "$CLANG_DIR" >/dev/null
    curl -LO https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman
    chmod +x antman
    ./antman -S
    popd >/dev/null
fi

# Resolve clang bin path
_clang_bin=$(find "$CLANG_DIR" -path '*/bin/clang' \( -type f -o -type l \) | head -n1)
if [[ -z "$_clang_bin" ]]; then
    # Last-resort: check if antman installed to ~/.neutron-tc
    _clang_bin=$(find "$HOME/.neutron-tc" -path '*/bin/clang' \( -type f -o -type l \) 2>/dev/null | head -n1)
    if [[ -n "$_clang_bin" ]]; then
        warn "Neutron installed to ~/.neutron-tc — symlinking to $CLANG_DIR"
        rm -rf "$CLANG_DIR"
        ln -sf "$HOME/.neutron-tc" "$CLANG_DIR"
        _clang_bin=$(find "$CLANG_DIR" -path '*/bin/clang' \( -type f -o -type l \) | head -n1)
    fi
fi
[[ -n "$_clang_bin" ]] || die "Cannot locate clang binary under $CLANG_DIR"
CLANG_BIN=$(dirname "$_clang_bin")
unset _clang_bin
export PATH="$CLANG_BIN:$PATH"

# Validate toolchain
[[ -x "$CLANG_BIN/clang"  ]] || die "clang binary not found in $CLANG_BIN"
[[ -x "$CLANG_BIN/ld.lld" ]] || die "ld.lld binary not found in $CLANG_BIN"
success "Toolchain: $(clang --version | head -n1)"

cd "$KSRC"
LINUX_VERSION=$(make kernelversion)
KVER="$LINUX_VERSION"
LINUX_MAJOR="${LINUX_VERSION%%.*}"
COMPILER_STRING=$(clang --version | head -n1)
k_lastcommit=$(git -C "$KSRC" rev-parse --short HEAD)
LASTCOMMITS=$(git -C "$KSRC" log -5 --pretty=format:"- %h %s (%an)" | \
    sed ':a;N;$!ba;s/\n/\\n/g')

info "Kernel version : $LINUX_VERSION"
info "Last commit    : $k_lastcommit"

# Locate defconfig
DEFCONFIG_FILE=$(find "$KSRC/arch/arm64/configs" -name "$KERNEL_DEFCONFIG" -print -quit)
[[ -f "$DEFCONFIG_FILE" ]] || die "Defconfig '$KERNEL_DEFCONFIG' not found"
DEFCONFIG="$DEFCONFIG_FILE"

# Variant Setup
info "Setting up variant: $VARIANT"

# Wipe any old KSU config lines
sed -i '/CONFIG_KSU/d'        "$DEFCONFIG"
sed -i '/CONFIG_KSU_SUSFS/d'  "$DEFCONFIG"

if [[ "$VARIANT" == "KSU" || "$VARIANT" == "SUSFS" ]]; then
    curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh" \
        | bash -s dev-susfs

    info "Patching All Managers support..."
    if [[ -d "KernelSU-Next" ]]; then
        patch -p1 -d KernelSU-Next < "$KERNEL_PATCHES/ksu-manager.patch" || die "ksu-manager patch failed"
    elif [[ -d "drivers/kernelsu" ]]; then
        patch -p1 -d drivers/kernelsu < "$KERNEL_PATCHES/ksu-manager.patch" || die "ksu-manager patch failed"
    else
        die "KernelSU directory not found after setup"
    fi
fi

case "$VARIANT" in
    VNL)
        echo "ENABLE_SUSFS=false" >> "${GITHUB_ENV:-/dev/null}"
        ;;

    KSU)
        echo "CONFIG_KSU=y"                    >> "$DEFCONFIG"
        echo "# CONFIG_KSU_SUSFS is not set"   >> "$DEFCONFIG"
        echo "ENABLE_SUSFS=false"              >> "${GITHUB_ENV:-/dev/null}"
        ;;

    SUSFS)
        git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu/ \
            -b gki-android12-5.10 sus
        rm -rf sus/.git
        cp -r sus/kernel_patches/fs .
        cp -r sus/kernel_patches/include .
        patch -p1 < sus/kernel_patches/50_add_susfs_in_gki-android12-5.10.patch \
            || die "SuSFS patch failed"
        rm -rf sus

        echo "CONFIG_KSU=y"         >> "$DEFCONFIG"
        echo "CONFIG_KSU_SUSFS=y"   >> "$DEFCONFIG"

        # Disable uname spoof to fix build
        KSU_SU_FILE=$(find drivers/ -name "supercalls.c" -print -quit)
        if [[ -f "$KSU_SU_FILE" ]]; then
            sed -i 's|#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME|#if 0 /* disabled */|' \
                "$KSU_SU_FILE" || true
        fi
        echo "ENABLE_SUSFS=true" >> "${GITHUB_ENV:-/dev/null}"
        ;;

    *)
        die "Unknown VARIANT: $VARIANT (valid: VNL | KSU | SUSFS)"
        ;;
esac

# Defconfig Tuning
info "Tuning defconfig..."

# HZ
sed -i '/CONFIG_HZ_/d; /CONFIG_HZ=/d' "$DEFCONFIG"
echo "CONFIG_HZ_${CONFIGHZ}=y" >> "$DEFCONFIG"
echo "CONFIG_HZ=${CONFIGHZ}"   >> "$DEFCONFIG"

# LTO
sed -i '/CONFIG_LTO_/d; /CONFIG_THINLTO/d; /CONFIG_LTO=/d' "$DEFCONFIG"
case "${LTOBUILD,,}" in
    thin)
        info "LTO: ThinLTO"
        echo "CONFIG_LTO_CLANG=y"      >> "$DEFCONFIG"
        echo "CONFIG_THINLTO=y"        >> "$DEFCONFIG"
        echo "CONFIG_LTO_CLANG_THIN=y" >> "$DEFCONFIG"
        echo "# CONFIG_LTO_NONE is not set" >> "$DEFCONFIG"
        ;;
    full|*)
        info "LTO: Full LTO"
        echo "CONFIG_LTO_CLANG=y"      >> "$DEFCONFIG"
        echo "CONFIG_LTO_CLANG_FULL=y" >> "$DEFCONFIG"
        echo "# CONFIG_THINLTO is not set"  >> "$DEFCONFIG"
        echo "# CONFIG_LTO_NONE is not set" >> "$DEFCONFIG"
        ;;
esac

# TCP Congestion
case "$TCPCONG" in
    westwood) use_westwood ;;
    bbrplus)  use_bbrplus  ;;
    bbr)      use_bbr      ;;
    *)        die "Unknown TCP congestion: $TCPCONG (valid: bbr | bbrplus | westwood)" ;;
esac

# Localversion
config --set-str CONFIG_LOCALVERSION "-${KERNEL_NAME}"
config --disable CONFIG_LOCALVERSION_AUTO
sed -i 's/echo "+"/# echo "+"/g' scripts/setlocalversion

export KBUILD_BUILD_USER
export KBUILD_BUILD_HOST
export KBUILD_BUILD_TIMESTAMP="$(date)"
export KCFLAGS="-w"
MAKE=$(command -v make)

MAKE_ARGS=(
    ARCH=arm64
    O="$OUTDIR"

    CC="clang"
    LD=ld.lld

    LLVM=1
    LLVM_IAS=1

    HOSTCC="clang"
    HOSTCXX=clang++

    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip

    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

    "-j$(nproc --all)"
)

KERNEL_IMAGE="$OUTDIR/arch/arm64/boot/Image"
MODULE_SYMVERS="$OUTDIR/Module.symvers"

# Generate Config
info "Generating config..."
$MAKE "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
$MAKE "${MAKE_ARGS[@]}" olddefconfig

# Defconfig-only
if [[ "${TODO:-}" == "defconfig" ]]; then
    info "Uploading defconfig..."
    upload_file "$OUTDIR/.config"
    exit 0
fi

# Clone AnyKernel3 in background
info "Cloning AnyKernel3 from $(simplify_gh_url "$ANYKERNEL_REPO") (background)..."
git clone -q --depth=1 "$ANYKERNEL_REPO" -b "$ANYKERNEL_BRANCH" "$WORKDIR/anykernel" &
AK3_CLONE_PID=$!

# Build Kernel
info "Building kernel with $(nproc --all) threads..."
$MAKE "${MAKE_ARGS[@]}"

BUILD_END=$(date +%s)
BUILD_ELAPSED=$(( BUILD_END - BUILD_START ))
BUILD_MIN=$(( BUILD_ELAPSED / 60 ))
BUILD_SEC=$(( BUILD_ELAPSED % 60 ))
success "Kernel built in ${BUILD_MIN}m ${BUILD_SEC}s"

# Validate Output
[[ -f "$KERNEL_IMAGE" ]] || die "Kernel Image not found at $KERNEL_IMAGE"
IMAGE_SIZE=$(du -sh "$KERNEL_IMAGE" | cut -f1)
info "Image size: $IMAGE_SIZE"

# KMI Check
if [[ "$LINUX_MAJOR" -eq 6 ]]; then
    KMI_CHECK_SCRIPT="$WORKDIR/py/kmi-check-6.x.py"
    KMI_ABI="$KSRC/android/abi_gki_aarch64.stg"
else
    KMI_CHECK_SCRIPT="$WORKDIR/py/kmi-check-5.x.py"
    KMI_ABI="$KSRC/android/abi_gki_aarch64.xml"
fi
"$KMI_CHECK_SCRIPT" "$KMI_ABI" "$MODULE_SYMVERS" || \
    warn "KMI mismatch detected — vendor modules may fail to load"

BUILD_DATE=$(TZ=Asia/Jakarta date +"%Y%m%d")
AK3_ZIP_NAME="AK3-${KERNEL_NAME}-${KVER}-${VARIANT}-${BUILD_DATE}.zip"

wait "$AK3_CLONE_PID" || die "AnyKernel3 clone failed"
cd "$WORKDIR/anykernel"

cp "$KERNEL_IMAGE" .

info "Zipping AnyKernel3 package..."
zip -r9 "$WORKDIR/$AK3_ZIP_NAME" ./* -x "*.git*"
cd "$WORKDIR"

ZIP_FINAL_SIZE=$(du -sh "$WORKDIR/$AK3_ZIP_NAME" | cut -f1)
success "Package: $AK3_ZIP_NAME ($ZIP_FINAL_SIZE)"

echo "BASE_NAME=${KERNEL_NAME}-${VARIANT}" >> "${GITHUB_ENV:-/dev/null}"

# Move to Artifacts
ARTIFACT_DIR="$WORKDIR/artifacts"
ZIP_PATH="$ARTIFACT_DIR/$AK3_ZIP_NAME"
mkdir -p "$ARTIFACT_DIR"
mv "$WORKDIR/$AK3_ZIP_NAME" "$ARTIFACT_DIR/"

# Telegram Notification
text_tg=$(cat << EOF
📱 *Kernel Version*: \`${LINUX_VERSION}\`
📅 *Build Date*: \`${KBUILD_BUILD_TIMESTAMP}\`
⚙️ *Variant*: \`${VARIANT}\`
🚀 *LTO*: \`${LTOBUILD}\`
🛠 *Compiler*: \`${COMPILER_STRING}\`
⏱ *Build Time*: \`${BUILD_MIN}m ${BUILD_SEC}s\`
📦 *Package Size*: \`${ZIP_FINAL_SIZE}\`

🔖 *Last Commit*: [${k_lastcommit}](${KERNEL_REPO}/commit/${k_lastcommit})

📜 *Recent Changes*:
\`\`\`
${LASTCOMMITS}
\`\`\`
EOF
)

if [[ "${BUILD_TYPE:-}" != "release" ]]; then
    info "Sending test build to Telegram..."
    upload_file "$ZIP_PATH" "$text_tg"
fi

# Cleanup
info "Cleaning up build artifacts..."
rm -rf "$GKI_DIR" "$CLANG_DIR" "$WORKDIR/anykernel" "$OUTDIR"
success "Done! Total time: ${BUILD_MIN}m ${BUILD_SEC}s"

exit 0
