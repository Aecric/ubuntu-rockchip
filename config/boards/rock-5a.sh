# shellcheck shell=bash

export BOARD_NAME="ROCK 5A"
export BOARD_MAKER="Radxa"
export BOARD_SOC="Rockchip RK3588S"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="rock-5a-rk3588s"
export UBOOT_RULES_TARGET_EXTRA="rock-5a-spi-rk3588s"
export COMPATIBLE_SUITES=("jammy" "noble" "oracular")
export COMPATIBLE_FLAVORS=("server" "desktop")

function config_image_hook__rock-5a() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"

    if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ]; then

        # Replace sources list with Tsinghua University's mirror
        chroot "${rootfs}" cat > ${rootfs}/etc/apt/sources.list << EOF
        deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${suite} main restricted universe multiverse
        deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${suite}-updates main restricted universe multiverse
        deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${suite}-backports main restricted universe multiverse
        deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${suite}-security main restricted universe multiverse
EOF
        # Install panfork
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/panfork-mesa
        chroot "${rootfs}" add-apt-repository ppa:mozillateam/ppa
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get -y install mali-g610-firmware
        chroot "${rootfs}" apt-get -y dist-upgrade

        # Install libmali blobs alongside panfork
        chroot "${rootfs}" apt-get -y install libmali-g610-x11

        # Install the rockchip camera engine
        chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588

        # Fix Bluetooth not working with Radxa RTL8852BE WiFi + BT card
        # cp "${overlay}/usr/lib/systemd/system/radxa-a8-bluetooth.service" "${rootfs}/usr/lib/systemd/system/radxa-a8-bluetooth.service"
        # chroot "${rootfs}" systemctl enable radxa-a8-bluetooth


        #RM
        chroot "${rootfs}" apt-get -y remove --purge libreoffice*
        chroot "${rootfs}" apt-get -y remove --purge gnome-games gnome-sudoku gnome-mahjongg gnome-mines aisleriot 
        chroot "${rootfs}" apt-get -y remove --purge thunderbird*
        chroot "${rootfs}" apt-get autoremove -y
        chroot "${rootfs}" apt-get clean


        # Fix and configure audio device
        mkdir -p "${rootfs}/usr/lib/scripts"
        cp "${overlay}/usr/lib/scripts/alsa-audio-config" "${rootfs}/usr/lib/scripts/alsa-audio-config"
        cp "${overlay}/usr/lib/systemd/system/alsa-audio-config.service" "${rootfs}/usr/lib/systemd/system/alsa-audio-config.service"
        chroot "${rootfs}" systemctl enable alsa-audio-config
    fi

    return 0
}
