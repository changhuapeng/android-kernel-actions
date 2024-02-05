#!/usr/bin/env bash

msg(){
    echo
    echo "==> $*"
    echo
}

err(){
    echo 1>&2
    echo "==> $*" 1>&2
    echo 1>&2
}

set_output(){
    echo "$1=$2" >> $GITHUB_OUTPUT
}

extract_tarball(){
    echo "Extracting $1 to $2"
    tar xf "$1" -C "$2"
}

arch="${ARCH:?'was not set'}"
compiler="${COMPILER:?'was not set'}"
defconfig="${DEFCONFIG:?'was not set'}"
image="${IMAGE:?'was not set'}"
dtb="${DTB:?'was not set'}"
dtbo="${DTBO:?'was not set'}"
kernelsu="${KERNELSU:?'was not set'}"
kprobes="${KPROBES:?'was not set'}"
ksu_version="${KSU_VERSION:--}"

workdir="$GITHUB_WORKSPACE"
repo_name="${GITHUB_REPOSITORY/*\/}"
zipper_path="${ZIPPER_PATH:-zipper}"
kernel_path="${KERNEL_PATH:-.}"
name="${NAME:-$repo_name}"
python_version="${PYTHON_VERSION:-3}"

msg "Updating container..."
sudo apt-get update -y -q && sudo apt-get upgrade -y -q
msg "Installing essential packages..."
sudo apt-get install -y -q --no-install-recommends bc bison build-essential \
    cpio ca-certificates curl device-tree-compiler flex git \
    gnupg kmod libelf-dev libssl-dev libtfm-dev libxml2-utils \
    python2 python3 wget zip
sudo ln -sf "/usr/bin/python${python_version}" /usr/bin/python
set_output hash "$(cd "$kernel_path" && git rev-parse HEAD || exit 127)"
msg "Installing toolchain..."
if [[ $arch = "arm64" ]]; then
    arch_opts="ARCH=${arch} SUBARCH=${arch}"
    export ARCH="$arch"
    export SUBARCH="$arch"

    if [[ $compiler = gcc/* ]]; then
        ver_number="${compiler/gcc\/}"
        make_opts=""
        host_make_opts=""

        if ! sudo apt-get install -y -q --no-install-recommends gcc-"$ver_number" g++-"$ver_number" \
            gcc-"$ver_number"-aarch64-linux-gnu gcc-"$ver_number"-arm-linux-gnueabi; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi

        ln -sf /usr/bin/gcc-"$ver_number" /usr/bin/gcc
        ln -sf /usr/bin/g++-"$ver_number" /usr/bin/g++
        ln -sf /usr/bin/aarch64-linux-gnu-gcc-"$ver_number" /usr/bin/aarch64-linux-gnu-gcc
        ln -sf /usr/bin/arm-linux-gnueabi-gcc-"$ver_number" /usr/bin/arm-linux-gnueabi-gcc

        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = clang/* ]]; then
        ver="${compiler/clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        if $binutils; then
            additional_packages="binutils binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang DTC_EXT=dtc"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            # Most android kernels still need binutils as the assembler, but it will
            # not be used when the Makefile is patched to make use of LLVM_IAS option
            additional_packages="binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi"
            make_opts="CC=clang DTC_EXT=dtc LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        if ! sudo apt-get install -y -q --no-install-recommends clang-"$ver_number" \
            lld-"$ver_number" llvm-"$ver_number" $additional_packages; then
            err "Compiler package not found, refer to the README for details"
            exit 1
        fi

        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang
        ln -sf /usr/bin/clang-"$ver_number" /usr/bin/clang++
        ln -sf /usr/bin/ld.lld-"$ver_number" /usr/bin/ld.lld

        for i in /usr/bin/llvm-*-"$ver_number"; do
            ln -sf "$i" "${i/-$ver_number}"
        done

        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = proton-clang/* ]]; then
        ver="${compiler/proton-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://github.com/kdrag0n/proton-clang/archive/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        # Due to different time in container and the host,
        # disable certificate check
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/proton-clang-"${ver_number}".tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        if $binutils; then
            make_opts="CC=clang DTC_EXT=dtc"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang DTC_EXT=dtc LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        sudo apt-get install -y -q --no-install-recommends libgcc-10-dev || exit 127
        extract_tarball /tmp/proton-clang-"${ver_number}".tar.gz /
        cd /proton-clang-"${ver_number}"* || exit 127
        proton_path="$(pwd)"
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$proton_path/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = aosp-clang/* ]]; then
        ver="${compiler/aosp-clang\/}"
        ver_number="${ver/\/binutils}"
        url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/${ver_number}.tar.gz"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-clang.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm64.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-arm.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        url="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/+archive/refs/heads/android12L-release.tar.gz"
        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/aosp-gcc-host.tar.gz &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        mkdir -p /aosp-clang /aosp-gcc-arm64 /aosp-gcc-arm /aosp-gcc-host
        extract_tarball /tmp/aosp-clang.tar.gz /aosp-clang
        extract_tarball /tmp/aosp-gcc-arm64.tar.gz /aosp-gcc-arm64
        extract_tarball /tmp/aosp-gcc-arm.tar.gz /aosp-gcc-arm
        extract_tarball /tmp/aosp-gcc-host.tar.gz /aosp-gcc-host

        for i in /aosp-gcc-host/bin/x86_64-linux-*; do
            ln -sf "$i" "${i/x86_64-linux-}"
        done

        if $binutils; then
            make_opts="CC=clang DTC_EXT=dtc"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang DTC_EXT=dtc LD=ld.lld NM=llvm-nm STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        sudo apt-get install -y -q --no-install-recommends libgcc-10-dev || exit 127

        export PATH="/aosp-clang/bin:/aosp-gcc-arm64/bin:/aosp-gcc-arm/bin:/aosp-gcc-host/bin:$PATH"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-android-"
        export CROSS_COMPILE_ARM32="arm-linux-androideabi-"
    elif [[ $compiler = neutron-clang/* ]]; then
        ver="${compiler/neutron-clang\/}"
        ver_number="${ver/\/binutils}"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        if $binutils; then
            make_opts="CC=clang DTC_EXT=dtc"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang DTC_EXT=dtc LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        sudo apt-get install -y -q --no-install-recommends libgcc-10-dev zstd libxml2 libarchive-tools || exit 127
        mkdir neutron-clang
        cd neutron-clang || exit 127
        curl -LO "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman"
        if ! bash antman -S=${ver_number} &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi
        bash antman --patch=glibc &>/dev/null
        bash antman --info
        neutron_path="$(pwd)"
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$neutron_path/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    elif [[ $compiler = greenforce-clang/* ]]; then
        ver="${compiler/greenforce-clang\/}"
        ver_number="${ver/\/binutils}"
        tag_number="$(awk -F- '{print $2}' <<< ${ver_number})"
        url="https://github.com/greenforce-project/greenforce_clang/releases/download/${tag_number}/greenforce-clang-${ver_number}.tar.zst"
        binutils="$([[ $ver = */binutils ]] && echo true || echo false)"

        echo "Downloading $url"
        if ! wget --no-check-certificate "$url" -O /tmp/greenforce-clang-"${ver_number}".tar.zst &>/dev/null; then
            err "Failed downloading toolchain, refer to the README for details"
            exit 1
        fi

        if $binutils; then
            make_opts="CC=clang DTC_EXT=dtc"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++"
        else
            make_opts="CC=clang DTC_EXT=dtc LD=ld.lld NM=llvm-nm AR=llvm-ar STRIP=llvm-strip OBJCOPY=llvm-objcopy"
            make_opts+=" OBJDUMP=llvm-objdump READELF=llvm-readelf LLVM_IAS=1"
            host_make_opts="HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld HOSTAR=llvm-ar"
        fi

        sudo apt-get install -y -q --no-install-recommends libgcc-10-dev zstd || exit 127

        mkdir -p greenforce-clang
        cd greenforce-clang || exit 127
        tar -I zstd -xf /tmp/greenforce-clang-"${ver_number}".tar.zst
        greenforce_path="$(pwd)"
        cd "$workdir"/"$kernel_path" || exit 127

        export PATH="$greenforce_path/bin:${PATH}"
        export CLANG_TRIPLE="aarch64-linux-gnu-"
        export CROSS_COMPILE="aarch64-linux-gnu-"
        export CROSS_COMPILE_ARM32="arm-linux-gnueabi-"
    else
        err "Unsupported toolchain string. refer to the README for more detail"
        exit 100
    fi
else
    err "Currently this action only supports arm64, refer to the README for more detail"
    exit 100
fi

cd "$workdir"/"$kernel_path" || exit 127
ksu_name=""
if $kernelsu; then
    msg "Integrating KernelSU for non GKI kernel..."
    if ! curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$ksu_version"; then
        err "Failed downloading KernelSU"
        exit 1
    fi

    if $kprobes; then
        sed -i -E "s/^#*\s*CONFIG_KPROBES[ is|=].*/CONFIG_KPROBES=y/i" arch/"$arch"/configs/"$defconfig"
        if ! grep -q "CONFIG_KPROBES=y" arch/"$arch"/configs/"$defconfig"; then
            echo "CONFIG_KPROBES=y" >> arch/"$arch"/configs/"$defconfig"
        fi

        sed -i -E "s/^#*\s*CONFIG_HAVE_KPROBES[ is|=].*/CONFIG_HAVE_KPROBES=y/i" arch/"$arch"/configs/"$defconfig"
        if ! grep -q "CONFIG_HAVE_KPROBES=y" arch/"$arch"/configs/"$defconfig"; then
            echo "CONFIG_HAVE_KPROBES=y" >> arch/"$arch"/configs/"$defconfig"
        fi

        sed -i -E "s/^#*\s*CONFIG_KPROBE_EVENTS[ is|=].*/CONFIG_KPROBE_EVENTS=y/i" arch/"$arch"/configs/"$defconfig"
        if ! grep -q "CONFIG_KPROBE_EVENTS=y" arch/"$arch"/configs/"$defconfig"; then
            echo "CONFIG_KPROBE_EVENTS=y" >> arch/"$arch"/configs/"$defconfig"
        fi
    else
        echo "Manually integrating KernelSU..."
        sed -i -e "s/CONFIG_KPROBES=y/# CONFIG_KPROBES is not set/i" \
            -e "s/CONFIG_HAVE_KPROBES=y/# CONFIG_HAVE_KPROBES is not set/i" \
            -e "s/CONFIG_KPROBE_EVENTS=y/# CONFIG_KPROBE_EVENTS is not set/i" \
            arch/"$arch"/configs/"$defconfig"

        sed -i -E "s/^#*\s*CONFIG_KSU[ is|=].*/CONFIG_KSU=y/i" arch/"$arch"/configs/"$defconfig"
        if ! grep -q "CONFIG_KSU=y" arch/"$arch"/configs/"$defconfig"; then
            echo "CONFIG_KSU=y" >> arch/"$arch"/configs/"$defconfig"
        fi

        bash "$GITHUB_ACTION_PATH"/patches/ksu_integration.sh
        if ! grep -q "extern bool ksu_execveat_hook __read_mostly;" fs/exec.c ||
          ! grep -q "if (unlikely(ksu_execveat_hook))" fs/exec.c ||
          ! grep -q "extern int ksu_handle_faccessat" fs/open.c ||
          ! grep -q "ksu_handle_faccessat(&dfd, &filename, &mode, NULL);" fs/open.c ||
          ! grep -q "extern bool ksu_vfs_read_hook __read_mostly;" fs/read_write.c ||
          ! grep -q "if (unlikely(ksu_vfs_read_hook))" fs/read_write.c ||
          ! grep -q "extern int ksu_handle_stat" fs/stat.c ||
          ! grep -q "ksu_handle_stat(&dfd, &filename, &flag" fs/stat.c ||
          ! grep -q "extern bool ksu_input_hook __read_mostly;" drivers/input/input.c ||
          ! grep -q "if (unlikely(ksu_input_hook))" drivers/input/input.c; then
            err "Failed integrating KernelSU manually, refer to the instructions here: https://kernelsu.org/guide/how-to-integrate-for-non-gki.html#manually-modify-the-kernel-source"
            exit 3
        else
            echo "Kernel is patched for KernelSU"
        fi
    fi

    bash "$GITHUB_ACTION_PATH"/patches/backport_umount.sh
    if ! grep -q "static int can_umount" fs/namespace.c ||
      grep -q "if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)" KernelSU/kernel/core_hook.c; then
        err "Failed backporting umount modules support"
        exit 3
    else
        echo "Kernel is patched for umount modules support"
    fi

    cd "$workdir"/KernelSU || exit 127
    KSU_VER=$(($(git rev-list --count HEAD) + 10200))
    ksu_name="-KSU-$KSU_VER"
    ksu_commit="$(git rev-parse HEAD)"
    release_file="$workdir"/release.txt
    printf "Integrated with https://github.com/tiann/KernelSU/commit/$ksu_commit" >> $release_file
    printf "\n\n###### IMPORTANT: This KSU kernel build is not tested extensively, use at your own risk!" >> $release_file
    set_output notes "$release_file"
fi
echo "Packages installed:"
sudo apt list -q --installed

cd "$workdir"/"$kernel_path" || exit 127
start_time="$(date +%s)"
date="$(date +%Y%m%d-%H%M)"
tag="$(git branch | sed 's/*\ //g')"
echo "branch/tag: $tag"
set_output build_date "$date"

export KBUILD_BUILD_USER="$(git rev-parse --short HEAD | cut -c1-7)"
export KBUILD_BUILD_HOST="$GITHUB_REPOSITORY"
export LOCALVERSION="-$(echo $defconfig | cut -d "_" -f 1)${ksu_name}"

echo "make options:" $arch_opts $make_opts $host_make_opts
msg "Generating defconfig from \`make $defconfig\`..."
if ! make O=out $arch_opts $make_opts $host_make_opts "$defconfig"; then
    err "Failed generating .config, make sure it is actually available in arch/${arch}/configs/ and is a valid defconfig file"
    exit 2
fi
msg "Begin building kernel..."

make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)" prepare

if ! make O=out $arch_opts $make_opts $host_make_opts -j"$(nproc --all)"; then
    err "Failed building kernel, probably the toolchain is not compatible with the kernel, or kernel source problem"
    exit 3
fi
set_output elapsed_time "$(echo "$(date +%s)"-"$start_time" | bc)"
msg "Packaging the kernel..."
zip_filename="${name}-${date}${ksu_name}.zip"
if [[ -e "$workdir"/"$zipper_path" ]]; then
    cp out/arch/"$arch"/boot/"$image" "$workdir"/"$zipper_path"/"$image"

    if $dtb; then
        if ! cp out/arch/"$arch"/boot/dtb "$workdir"/"$zipper_path"/dtb &>/dev/null; then
            find out/arch/"$arch"/boot -type f -name "*.dtb" -exec cp {} "$workdir"/"$zipper_path"/dtb \;
        fi

        if [[ ! -f "$workdir"/"$zipper_path"/dtb ]]; then
            err "dtb image not found"
            exit 1
        fi
    fi

    if $dtbo; then
        if ! cp out/arch/"$arch"/boot/dtbo.img "$workdir"/"$zipper_path"/dtbo.img &>/dev/null; then
            find out/arch/"$arch"/boot -type f -name "*.dtbo" -exec cp {} /tmp/tmp.dtbo \;
        fi
        if [[ -f /tmp/tmp.dtbo ]]; then
            echo "Packing dtbo file into image"
            url="https://android.googlesource.com/platform/system/libufdt/+archive/refs/tags/android-platform-14.0.0_r1/utils.tar.gz"
            if ! wget --no-check-certificate "$url" -O /tmp/libufdt-utils.tar.gz &>/dev/null; then
                err "Failed downloading mkdtboimg.py script"
                exit 1
            fi
            mkdir -p libufdt-utils
            extract_tarball /tmp/libufdt-utils.tar.gz libufdt-utils
            cd libufdt-utils/src || exit 127
            python mkdtboimg.py create "$workdir"/"$zipper_path"/dtbo.img --page_size=4096 /tmp/tmp.dtbo
        fi

        if [[ ! -f "$workdir"/"$zipper_path"/dtbo.img ]]; then
            err "dtbo image not found"
            exit 1
        fi
    fi

    cd "$workdir"/"$zipper_path" || exit 127
    sed -i -E "s/(kernel.string=).*/\1${name}${ksu_name} kernel by $GITHUB_REPOSITORY_OWNER/i" "$workdir"/"$zipper_path"/anykernel.sh
    rm -rf .git
    zip -r9 "$zip_filename" . -x .gitignore README.md || exit 127
    set_output outfile "$workdir"/"$zipper_path"/"$zip_filename"
    cd "$workdir" || exit 127
    exit 0
else
    msg "No zip template provided, releasing the kernel image instead"
    set_output image out/arch/"$arch"/boot/"$image"

    if $dtb; then
        if [[ -f out/arch/"$arch"/boot/dtb ]]; then
            set_output dtb out/arch/"$arch"/boot/dtb
        else
            find out/arch/"$arch"/boot -type f -name "*.dtb" -exec cp {} /tmp/dtb \;
            if [[ -f /tmp/dtb ]]; then
                set_output dtb /tmp/dtb
            fi
        fi
    fi

    if $dtbo; then
        if [[ -f out/arch/"$arch"/boot/dtbo.img ]]; then
            set_output dtbo out/arch/"$arch"/boot/dtbo.img
        else
            find out/arch/"$arch"/boot -type f -name "*.dtbo" -exec cp {} /tmp/tmp.dtbo \;
            if [[ -f /tmp/tmp.dtbo ]]; then
                echo "Packing dtbo file into image"
                url="https://android.googlesource.com/platform/system/libufdt/+archive/refs/tags/android-platform-14.0.0_r1/utils.tar.gz"
                if ! wget --no-check-certificate "$url" -O /tmp/libufdt-utils.tar.gz &>/dev/null; then
                    err "Failed downloading mkdtboimg.py script"
                    exit 1
                fi
                mkdir -p libufdt-utils
                extract_tarball /tmp/libufdt-utils.tar.gz libufdt-utils
                cd libufdt-utils/src || exit 127
                python mkdtboimg.py create /tmp/dtbo.img --page_size=4096 /tmp/tmp.dtbo
                set_output dtbo /tmp/dtbo.img
            fi
        fi
    fi

    exit 0
fi
