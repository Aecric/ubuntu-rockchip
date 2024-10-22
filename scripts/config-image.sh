#!/bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_package="$(basename "$(find u-boot-"${BOARD}"_*.deb | sort | tail -n1)")"
    if [ ! -e "$uboot_package" ]; then
        echo 'Error: could not find the u-boot package'
        exit 1
    fi

    linux_image_package="$(basename "$(find linux-image-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_image_package" ]; then
        echo "Error: could not find the linux image package"
        exit 1
    fi

    linux_headers_package="$(basename "$(find linux-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_headers_package" ]; then
        echo "Error: could not find the linux headers package"
        exit 1
    fi

    linux_modules_package="$(basename "$(find linux-modules-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_modules_package" ]; then
        echo "Error: could not find the linux modules package"
        exit 1
    fi

    linux_buildinfo_package="$(basename "$(find linux-buildinfo-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_buildinfo_package" ]; then
        echo "Error: could not find the linux buildinfo package"
        exit 1
    fi

    linux_rockchip_headers_package="$(basename "$(find linux-rockchip-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_rockchip_headers_package" ]; then
        echo "Error: could not find the linux rockchip headers package"
        exit 1
    fi
fi

setup_mountpoint() {
    local mountpoint="$1"

    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi

    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    # Provide more up to date apparmor features, matching target kernel
    # cgroup2 mount for LP: 1944004
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

teardown_mountpoint() {
    # Reverse the operations from setup_mountpoint
    local mountpoint
    mountpoint=$(realpath "$1")

    # ensure we have exactly one trailing slash, and escape all slashes for awk
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    # sort -r ensures that deeper mountpoints are unmounted first
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
}

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# Override localisation settings to address a perl warning
export LC_ALL=C

# Debootstrap options
chroot_dir_fs=rootfs
overlay_dir=../overlay

# Extract the compressed root filesystem
rm -rf ${chroot_dir_fs} && mkdir -p ${chroot_dir_fs}
tar -xpJf "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir_fs}


RELEASE=${SUITE}
ARCH="arm64"
TARGET_DIR="/ubuntu-$RELEASE-$ARCH"
mv ${chroot_dir_fs}$TARGET_DIR/* ${chroot_dir_fs}
rm -rf ${chroot_dir_fs}$TARGET_DIR/
chroot_dir="$chroot_dir_fs"


# Mount the root filesystem
setup_mountpoint $chroot_dir

# Update packages
chroot $chroot_dir apt-get update
chroot $chroot_dir apt-get -y upgrade


# Run config hook to handle board specific changes
if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi 

# Download and install U-Boot
if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y install "u-boot-${BOARD}"
else
    cp "${uboot_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} dpkg -i "/tmp/${uboot_package}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${uboot_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"

    cp "${linux_image_package}" "${linux_headers_package}" "${linux_modules_package}" "${linux_buildinfo_package}" "${linux_rockchip_headers_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{ print \$2 }')"
    chroot ${chroot_dir} /bin/bash -c "dpkg -i /tmp/{${linux_image_package},${linux_modules_package},${linux_buildinfo_package},${linux_rockchip_headers_package}}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_image_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_modules_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_buildinfo_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_rockchip_headers_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
fi

# Update the initramfs
chroot ${chroot_dir} update-initramfs -u

# 创建用户 radxa
chroot ${chroot_dir} adduser radxa --gecos "" --disabled-password
echo "radxa:radxa" | chroot ${chroot_dir} chpasswd
chroot ${chroot_dir} usermod -aG sudo,audio,video,plugdev,render,dialout radxa

# 配置默认语言为 en_US.UTF-8
chroot ${chroot_dir} locale-gen en_US.UTF-8
chroot ${chroot_dir} update-locale LANG=en_US.UTF-8

# 为 radxa 用户设置语言环境
chroot ${chroot_dir} su - radxa -c 'echo "export LANG=en_US.UTF-8" >> ~/.bashrc'
chroot ${chroot_dir} su - radxa -c 'echo "export LANGUAGE=en_US:en" >> ~/.bashrc'

#SetHostName
echo "ums" > ${chroot_dir}/etc/hostname
chroot ${chroot_dir} bash -c "echo '127.0.1.1 ums' >> /etc/hosts"

chroot ${chroot_dir} su - radxa -c 'sed -i "/live/d" ~/.bashrc'
chroot ${chroot_dir} su - radxa -c 'sed -i "/live/d" ~/.profile'
chroot ${chroot_dir} rm -f /etc/live*
chroot ${chroot_dir} systemctl restart systemd-hostnamed

# 以 radxa 用户运行一次 code-server 并在 5 秒后结束
chroot ${chroot_dir} su - radxa -c 'timeout 5s code-server &'
# 等待 code-server 生成配置文件
sleep 6
# 清空并写入新的配置到 /home/radxa/.config/code-server/config.yaml
chroot ${chroot_dir} su - radxa -c 'echo -e "bind-addr: 0.0.0.0:8080\nauth: password\npassword: qwer123\ncert: false" > /home/radxa/.config/code-server/config.yaml'

# 为用户 radxa 设置 ROS 环境
chroot ${chroot_dir} su - radxa -c 'echo "source /opt/ros/\$(ls /opt/ros)*/setup.bash" >> ~/.bashrc'

# 确保 bashrc 的更改立即生效（可选）
chroot ${chroot_dir} su - radxa -c 'source ~/.bashrc'

# 安装常用的 ROS 工具（例如 rosdep、colcon）
chroot ${chroot_dir} bash -c "sudo apt-get install -y python3-rosdep python3-colcon-common-extensions"
# chroot ${chroot_dir} bash -c "sudo rosdep init"
# chroot ${chroot_dir} su - radxa -c 'rosdep update'

#Tuna mirrors
cat << EOF | chroot ${chroot_dir} tee /etc/apt/sources.list > /dev/null
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${SUITE} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${SUITE}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${SUITE}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${SUITE}-security main restricted universe multiverse
EOF

# Remove packages
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean
chroot ${chroot_dir} apt-get -y autoremove
# Umount the root filesystem
teardown_mountpoint $chroot_dir

# Compress the root filesystem and then build a disk image
cd ${chroot_dir} && tar -cpf "../ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"