#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

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

if [[ -f ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz ]]; then
    exit 0
fi

# 函数：设置挂载点
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
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

# 函数：拆卸挂载点
teardown_mountpoint() {
    local mountpoint
    mountpoint=$(realpath "$1")

    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
}

# 设置变量
RELEASE=${SUITE}
ARCH="arm64"
TARGET_DIR="./ubuntu-$RELEASE-$ARCH"
MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports"
TEMP_DIR="/tmp/ubuntu-$RELEASE-$ARCH"
chroot_dir=$TARGET_DIR

# 检查是否安装了debootstrap，如果没有则提示安装
if ! command -v debootstrap &> /dev/null; then
    echo "debootstrap 未安装，请先安装 debootstrap。"
    echo "可以通过命令 sudo apt-get install debootstrap 来安装。"
    exit 1
fi
if [ ! -d "$TARGET_DIR" ]; then
    # 创建目标目录
    # 使用 debootstrap 构建最小系统
    debootstrap --arch="$ARCH" --variant=minbase "$RELEASE" "$TEMP_DIR" "$MIRROR_URL"
    mkdir -p "$TARGET_DIR"
    sudo mv "$TEMP_DIR"/* "$TARGET_DIR/"
    setup_mountpoint "$TARGET_DIR"
fi


# 如果 SUITE 是 noble，则忽略特定的包
if [ "${SUITE}" = "jammy" ]; then
    # 进入目标系统
    chroot $TARGET_DIR /bin/bash << 'EOL'
    # 设置基本的网络配置
    echo "nameserver 8.8.8.8" > /etc/resolv.conf

    echo "Building  ${SUITE} ${FLAVOR} "
    echo "Building  ${SUITE} ${FLAVOR} "
    echo "Building  ${SUITE} ${FLAVOR} "

    # 设置基本的环境变量
    export LANG=C.UTF-8

    # 添加基本的Ubuntu软件源
    cat <<EOF > /etc/apt/sources.list
    deb http://ports.ubuntu.com/ubuntu-ports jammy main restricted universe multiverse
    deb http://ports.ubuntu.com/ubuntu-ports jammy-updates main restricted universe multiverse
    deb http://ports.ubuntu.com/ubuntu-ports jammy-security main restricted universe multiverse
EOF

    # 更新包列表
    apt-get update

    # 安装 dpkg 和相关的基础包
    apt-get install -y dpkg apt libapt-pkg6.0 gpgv apt-utils debian-archive-keyring libc6 software-properties-common locales gnupg lsb-release

    # 添加 Rockchip 的 PPA 源
    add-apt-repository -y ppa:jjriek/rockchip
    add-apt-repository -y ppa:jjriek/rockchip-multimedia

    # 配置 APT pinning 以设置 Rockchip PPA 的优先级
    cat <<EOF > /etc/apt/preferences.d/extra-ppas.pref
    Package: *
    Pin: release o=LP-PPA-jjriek-rockchip
    Pin-Priority: 1001

    Package: *
    Pin: release o=LP-PPA-jjriek-rockchip-multimedia
    Pin-Priority: 1001
EOF


    # 添加 Firefox ESR 的 PPA 源
    add-apt-repository -y ppa:mozillateam/ppa

    # 优先安装来自 PPA 的 Firefox ESR 版本
    echo '
    Package: *
    Pin: release o=LP-PPA-mozillateam
    Pin-Priority: 1001
    ' > /etc/apt/preferences.d/mozilla-firefox

    # 再次更新包列表以包含新的PPA
    apt-get update

    # 安装基本的包
    apt-get install -y sudo wget net-tools curl

    # 安装最小的GNOME桌面环境
    apt-get install -y gnome-core gdm3 xwayland gnome-terminal nautilus gnome-system-monitor

    # 安装 Firefox ESR
    apt-get install -y firefox-esr

    # 清理不必要的包和缓存
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # 退出chroot环境
    exit
EOL
    echo "基本系统构建完成。"
    # 安装 ROS Humble (for Ubuntu 22.04)
    chroot $TARGET_DIR curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc | \
    chroot $TARGET_DIR tee /etc/apt/trusted.gpg.d/ros.asc > /dev/null && \
    chroot $TARGET_DIR sh -c "echo 'deb http://packages.ros.org/ros2/ubuntu ${SUITE} main' > /etc/apt/sources.list.d/ros2-latest.list" && \
    chroot $TARGET_DIR apt-get update && \
    chroot $TARGET_DIR apt-get install -y ros-humble-desktop
    echo "ROS 安装完成。"

elif [ "${SUITE}" = "noble" ]; then
    # 进入目标系统
    chroot $TARGET_DIR /bin/bash << 'EOL'
    # 设置基本的网络配置
    echo "nameserver 8.8.8.8" > /etc/resolv.conf

    echo "Building  ${SUITE} ${FLAVOR} "
    echo "Building  ${SUITE} ${FLAVOR} "
    echo "Building  ${SUITE} ${FLAVOR} "

    # 设置基本的环境变量
    export LANG=C.UTF-8

    # 添加基本的Ubuntu软件源
    cat <<EOF > /etc/apt/sources.list
    deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
    deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
    deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
EOF

    # 更新包列表
    apt-get update

    # 安装 dpkg 和相关的基础包
    apt-get install -y dpkg apt libapt-pkg6.0 gpgv apt-utils debian-archive-keyring libc6 software-properties-common locales  gnupg lsb-release

    # 添加 Rockchip 的 PPA 源（假设这些 PPA 仍然适用于 Ubuntu 24.04）
    add-apt-repository -y ppa:jjriek/rockchip
    add-apt-repository -y ppa:jjriek/rockchip-multimedia

    # 配置 APT pinning 以设置 Rockchip PPA 的优先级
    cat <<EOF > /etc/apt/preferences.d/extra-ppas.pref
    Package: *
    Pin: release o=LP-PPA-jjriek-rockchip
    Pin-Priority: 1001

    Package: *
    Pin: release o=LP-PPA-jjriek-rockchip-multimedia
    Pin-Priority: 1001
EOF

    cat <<EOF > /etc/apt/preferences.d/extra-ppas-ignore.pref
    Package: oem-*
    Pin: release o=LP-PPA-jjriek-rockchip-multimedia
    Pin-Priority: -1

    Package: ubiquity*
    Pin: release o=LP-PPA-jjriek-rockchip-multimedia
    Pin-Priority: -1
EOF
    # 添加 Firefox ESR 的 PPA 源（假设 PPA 支持 Ubuntu 24.04）
    add-apt-repository -y ppa:mozillateam/ppa

    # 优先安装来自 PPA 的 Firefox ESR 版本
    echo '
    Package: *
    Pin: release o=LP-PPA-mozillateam
    Pin-Priority: 1001
    ' > /etc/apt/preferences.d/mozilla-firefox

    # 再次更新包列表以包含新的PPA
    apt-get update

    # 安装基本的包
    apt-get install -y sudo wget net-tools curl

    # 安装最小的GNOME桌面环境
    apt-get install -y gnome-core gdm3 xwayland gnome-terminal nautilus gnome-system-monitor

    # 安装 Firefox ESR
    apt-get install -y firefox-esr

    # 清理不必要的包和缓存
    apt-get clean
    rm -rf /var/lib/apt/lists/*

    # 退出chroot环境
    exit
EOL
    echo "基本系统构建完成。"
    # 安装 ROS Jazzy (for Ubuntu 24.04)
    chroot $TARGET_DIR curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc | \
    chroot $TARGET_DIR tee /etc/apt/trusted.gpg.d/ros.asc > /dev/null && \
    chroot $TARGET_DIR sh -c "echo 'deb http://packages.ros.org/ros2/ubuntu ${SUITE} main' > /etc/apt/sources.list.d/ros2-latest.list" && \
    chroot $TARGET_DIR apt-get update && \
    chroot $TARGET_DIR apt-get install -y ros-jazzy-desktop
    echo "ROS 安装完成。"
else
    echo "未识别的 SUITE 值: ${SUITE}。请设置 SUITE 为 'jammy' 或 'noble'。"
fi



# 预装code-server
chroot $TARGET_DIR sh -c "curl -fsSL https://code-server.dev/install.sh | sh"

echo "Code 安装完成。"

# 拆卸挂载点
teardown_mountpoint "$TARGET_DIR"
echo "Ubuntu $RELASE_VERSION ARM64 最小镜像已成功构建于 $TARGET_DIR"
# 进入根文件系统目录并打包为 .tar.xz 文件
(tar -p -c --sort=name --xattrs ./$TARGET_DIR*) | xz -3 -T0 > "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"

# mv "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
echo "压缩完成：文件已保存为 ../ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"

rm -rf $TARGET_DIR
echo "清理"