#RM
chroot "${chroot_dir}" apt-get -y remove --purge libreoffice*
chroot "${chroot_dir}" apt-get -y remove --purge gnome-games gnome-sudoku gnome-mahjongg gnome-mines aisleriot chromium-browser
chroot "${chroot_dir}" apt-get -y remove --purge thunderbird*
#Firefox
chroot "${chroot_dir}" add-apt-repository -y ppa:mozillateam/ppa
chroot "${chroot_dir}" apt-get -y install firefox-esr

#ROS
chroot ${chroot_dir} bash -c '
apt-get update && apt-get install -y curl gnupg2 lsb-release
curl -sSL "https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc" | apt-key add -
sh -c 'echo "deb http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" > /etc/apt/sources.list.d/ros-latest.list'
apt-get update
'



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


# 预装code-server
chroot ${chroot_dir} bash -c "curl -fsSL https://code-server.dev/install.sh | sh"

# 以 radxa 用户运行一次 code-server 并在 5 秒后结束
chroot ${chroot_dir} su - radxa -c 'timeout 5s code-server &'
# 等待 code-server 生成配置文件
sleep 6
# 清空并写入新的配置到 /home/radxa/.config/code-server/config.yaml
chroot ${chroot_dir} su - radxa -c 'echo -e "bind-addr: 0.0.0.0:8080\nauth: password\npassword: qwer123\ncert: false" > /home/radxa/.config/code-server/config.yaml'

chroot ${chroot_dir} su - radxa -c 'echo "radxa" | sudo -S systemctl enable --now code-server@$USER'
# 预装ROS2
chroot ${chroot_dir} bash -c "
. /etc/os-release
if [ \"\$VERSION_CODENAME\" = \"jammy\" ]; then
    # 安装 ROS Humble (for Ubuntu 22.04)
    sudo apt-get update && sudo apt-get install -y curl gnupg lsb-release
    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc | sudo tee /etc/apt/trusted.gpg.d/ros.asc > /dev/null
    sudo sh -c 'echo \"deb http://packages.ros.org/ros2/ubuntu \${VERSION_CODENAME} main\" > /etc/apt/sources.list.d/ros2-latest.list'
    sudo apt-get update
    sudo apt-get install -y ros-humble-desktop
elif [ \"\$VERSION_CODENAME\" = \"noble\" ]; then
    # 安装 ROS Jazzy (for Ubuntu 24.04)
    sudo apt-get update && sudo apt-get install -y curl gnupg lsb-release
    sudo curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc | sudo tee /etc/apt/trusted.gpg.d/ros.asc > /dev/null
    sudo sh -c 'echo \"deb http://packages.ros.org/ros2/ubuntu \${VERSION_CODENAME} main\" > /etc/apt/sources.list.d/ros2-latest.list'
    sudo apt-get update
    sudo apt-get install -y ros-jazzy-desktop
fi
"
# 为用户 radxa 设置 ROS 环境
chroot ${chroot_dir} su - radxa -c 'echo "source /opt/ros/\$(ls /opt/ros)*/setup.bash" >> ~/.bashrc'


# 安装常用的 ROS 工具（例如 rosdep、colcon）
chroot ${chroot_dir} bash -c "sudo apt-get install -y python3-rosdep python3-colcon-common-extensions"
chroot ${chroot_dir} bash -c "sudo rosdep init"
chroot ${chroot_dir} su - radxa -c 'rosdep update'

# 确保 bashrc 的更改立即生效（可选）
chroot ${chroot_dir} su - radxa -c 'source ~/.bashrc'





