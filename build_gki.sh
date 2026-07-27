#!/usr/bin/env bash
#
# build_gki_5.10.260.sh
# ------------------------------------------------------------
# Script untuk build GKI (Generic Kernel Image) versi 5.10.260
# dengan:
#   - Clang 12 (otomatis ke-sync via repo manifest resmi Google)
#   - KernelSU-Next
#   - SUSFS (patch root-hiding)
#   - Custom defconfig + localversion
#
# Dijalankan di Ubuntu 22.04/24.04 x86_64. Siapkan storage kosong
# minimal ~30-50GB dan koneksi internet yang stabil.
#
# CATATAN PENTING:
#   Branch/tag/nama patch di bawah ini valid per Juli 2026.
#   Repo-repo ini (kernel/common, susfs4ksu, KernelSU-Next) sering
#   di-update, jadi kalau ada langkah yang gagal, cek ulang nama
#   tag/branch terbaru di:
#     - https://android.googlesource.com/kernel/common/+refs
#     - https://gitlab.com/simonpunk/susfs4ksu/-/branches
#     - https://github.com/KernelSU-Next/KernelSU-Next
# ------------------------------------------------------------

set -euo pipefail

########################################
# 0. KONFIGURASI - EDIT SESUAI KEBUTUHAN
########################################
WORKDIR="$HOME/gki-5.10.260-build"

# Branch manifest resmi Google untuk kernel common android12-5.10.
# repo sync akan otomatis menarik prebuilt Clang yang sesuai (clang-r416183b1
# a.k.a Clang 12.0.7 -- ini toolchain resmi yang dipakai kernel 5.10.260).
MANIFEST_BRANCH="common-android12-5.10"

# Tag resmi kernel/common yang persis 5.10.260
KERNEL_TAG="android12-5.10.260_r00"

# SUSFS (simonpunk/susfs4ksu) - branch disesuaikan dengan branch GKI di atas
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android12-5.10"
SUSFS_PATCH_NAME="50_add_susfs_in_gki-android12-5.10.patch"

# KernelSU-Next (fork resmi rifsxd, sekarang di bawah org KernelSU-Next)
KSU_NEXT_SETUP_URL="https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh"
KSU_NEXT_REF="next"     # opsi lain: "stable", "dev", "legacy", atau tag versi spesifik mis. "v1.0.9"

# Localversion custom -> akan muncul di `uname -r`
LOCALVERSION="-MyGKI-KSUN-SUSFS"

########################################
# 1. Install dependency build
########################################
echo ">>> Install dependency..."
sudo apt-get update
sudo apt-get install -y \
  git curl python3 python-is-python3 build-essential \
  bc bison flex libssl-dev libelf-dev rsync unzip zip ccache

# Install repo tool kalau belum ada
if ! command -v repo &>/dev/null; then
  echo ">>> Install repo tool..."
  mkdir -p "$HOME/.bin"
  curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo"
  chmod a+x "$HOME/.bin/repo"
  export PATH="$HOME/.bin:$PATH"
fi

git config --global user.name  "Kernel Builder" 2>/dev/null || true
git config --global user.email "builder@localhost" 2>/dev/null || true

########################################
# 2. Sync source kernel (termasuk toolchain Clang 12)
########################################
echo ">>> Sync source kernel via repo (branch: $MANIFEST_BRANCH)..."
mkdir -p "$WORKDIR"
cd "$WORKDIR"

repo init -u https://android.googlesource.com/kernel/manifest -b "$MANIFEST_BRANCH" --depth=1
repo sync -c --no-tags --no-clone-bundle -j"$(nproc --all)"

# Pin persis ke tag 5.10.260 (jaga-jaga kalau branch manifest sudah maju)
echo ">>> Checkout tag kernel: $KERNEL_TAG"
cd "$WORKDIR/common"
git fetch --tags --depth=1 origin "$KERNEL_TAG" || git fetch --tags
git checkout "$KERNEL_TAG"
cd "$WORKDIR"

# Verifikasi toolchain Clang yang ke-sync
CLANG_DIR=$(find "$WORKDIR/prebuilts/clang/host/linux-x86" -maxdepth 1 -type d -name 'clang-r*' | sort | tail -n1)
echo ">>> Toolchain Clang terdeteksi di: $CLANG_DIR"
"$CLANG_DIR/bin/clang" --version || echo "!!! Tidak bisa menjalankan clang, cek instalasi."

########################################
# 3. Clone & integrasikan KernelSU-Next
########################################
echo ">>> Setup KernelSU-Next..."
cd "$WORKDIR/common"
curl -LSs "$KSU_NEXT_SETUP_URL" | bash -s "$KSU_NEXT_REF"

########################################
# 4. Clone SUSFS & apply patch
########################################
echo ">>> Clone SUSFS ($SUSFS_BRANCH)..."
cd "$WORKDIR"
rm -rf susfs4ksu
git clone --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu

cd "$WORKDIR/common"
cp "../susfs4ksu/kernel_patches/$SUSFS_PATCH_NAME" ./
cp -r ../susfs4ksu/kernel_patches/fs/*            fs/
cp -r ../susfs4ksu/kernel_patches/include/linux/* include/linux/

echo ">>> Apply patch SUSFS ke kernel common..."
patch -p1 < "$SUSFS_PATCH_NAME" || {
  echo "!!! Ada hunk yang gagal (lihat file *.rej), cek & tempel manual dulu sebelum lanjut build."
}

echo ">>> Apply patch SUSFS ke KernelSU-Next..."
cd KernelSU-Next
cp ../../susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
patch -p1 < 10_enable_susfs_for_ksu.patch || {
  echo "!!! Patch KernelSU-Next ada yang gagal, cek file *.rej."
}
cd ..

########################################
# 5. Setting defconfig (KSU-Next + SUSFS + kprobe)
########################################
DEFCONFIG="$WORKDIR/common/arch/arm64/configs/gki_defconfig"
echo ">>> Menambahkan config KSU-Next & SUSFS ke $DEFCONFIG"

cat >> "$DEFCONFIG" <<'EOF'

# --- KernelSU-Next ---
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y

# --- SUSFS ---
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
EOF

# Catatan: nama CONFIG_KSU_SUSFS_* bisa berbeda tergantung versi susfs4ksu.
# Cek daftar lengkapnya setelah patch diterapkan di:
#   common/KernelSU-Next/kernel/Kconfig
# lalu sesuaikan blok di atas kalau ada opsi yang tidak dikenali saat build.

########################################
# 6. Setting localversion
########################################
echo ">>> Set localversion: $LOCALVERSION"
{
  echo "CONFIG_LOCALVERSION=\"$LOCALVERSION\""
  echo "CONFIG_LOCALVERSION_AUTO=n"
} >> "$DEFCONFIG"

# Kosongkan .scmversion supaya scripts/setlocalversion tidak menambahkan
# suffix hash git / "-dirty" otomatis di belakang localversion di atas.
touch "$WORKDIR/common/.scmversion"

########################################
# 7. Build
########################################
echo ">>> Mulai build kernel..."
cd "$WORKDIR"
export BUILD_CONFIG=common/build.config.gki.aarch64
export LTO=thin   # thin LTO = build lebih cepat & ringan RAM. Hapus baris ini kalau RAM >=24GB dan mau full LTO.

build/build.sh

echo ""
echo "==================================================="
echo " Build selesai."
echo " Cek hasil Image di:"
echo "   $WORKDIR/out/android12-5.10/dist/Image"
echo " (boot.img/Image.gz-dtb tergantung target device, cek folder dist/ lengkapnya)"
echo "==================================================="
