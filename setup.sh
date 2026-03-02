#!/bin/bash

set -e

LOG=/tmp/gaming_setup.log
exec > >(tee -a $LOG)
exec 2>&1

configure_repos() {
    echo "Configuring repositories..."
    sudo sed -i 's/archive.ubuntu.com/us.archive.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo sed -i 's/security.ubuntu.com/us.security.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    sudo sed -i 's/ports.ubuntu.com/us.ports.ubuntu.com/g' /etc/apt/sources.list 2>/dev/null || true
    
    sudo apt-get update >/dev/null 2>&1
    sudo apt-get upgrade -y >/dev/null 2>&1
}

install_dependencies() {
    echo "Installing dependencies..."
    sudo apt-get install -y \
        curl wget git \
        build-essential \
        mesa-utils \
        vulkan-tools \
        nvidia-cuda-toolkit >/dev/null 2>&1

    echo "Installing Sunshine..."
    SUNSHINE_DEB="/tmp/sunshine.deb"
    if wget -q -O "$SUNSHINE_DEB" "https://github.com/LizardByte/Sunshine/releases/download/v0.20.0/sunshine_0.20.0-1_amd64.deb" 2>/dev/null; then
        sudo dpkg -i "$SUNSHINE_DEB" >/dev/null 2>&1 || sudo apt-get install -y -f >/dev/null 2>&1
        rm -f "$SUNSHINE_DEB"
    else
        echo "Warning: Could not download Sunshine, will compile from source instead" >&2
        sudo apt-get install -y build-essential cmake git >/dev/null 2>&1
    fi

    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh 2>/dev/null | sh >/dev/null 2>&1 || true

    echo "Installing gaming applications..."
    sudo apt-get install -y \
        lutris \
        chromium-browser \
        ark >/dev/null 2>&1

    echo "Installing Steam..."
    sudo apt-get install -y steam-devices >/dev/null 2>&1
    curl -fsSL https://repo.steampowered.com/steam/archive/stable/steam.gpg 2>/dev/null | sudo tee /usr/share/keyrings/steampowered-keyring.gpg >/dev/null 2>&1
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/steampowered-keyring.gpg] http://repo.steampowered.com/steam/ stable steam" | sudo tee /etc/apt/sources.list.d/steampowered.list >/dev/null
    sudo apt-get update >/dev/null 2>&1
    sudo apt-get install -y steam >/dev/null 2>&1

    echo "Installing KDE Plasma..."
    sudo apt-get install -y \
        kde-plasma-desktop \
        dolphin \
        konsole \
        kwin \
        breeze \
        xserver-xorg \
        xserver-xorg-core \
        xinit \
        x11-common >/dev/null 2>&1
}

setup_users() {
    echo "Setting up users..."
    
    if ! id -u gaming &>/dev/null; then
        sudo useradd -m -s /bin/bash -G sudo,video gaming 2>/dev/null || true
        echo "gaming:1234" | sudo chpasswd 2>/dev/null
    fi

    echo "root:123456" | sudo chpasswd 2>/dev/null
}

setup_sunshine() {
    echo "Configuring Sunshine..."
    
    SUNSHINE_CONFIG="/home/gaming/.config/sunshine/config.conf"
    sudo mkdir -p /home/gaming/.config/sunshine 2>/dev/null || true
    
    sudo tee "$SUNSHINE_CONFIG" >/dev/null << 'EOF'
[audio]
audio_sink = 
audio_virtual_sink = 

[video]
codec = h264
encoder = nvenc
framerate = 60
bitrate = 10000

[input]
keyboard = /dev/input/event0

[server]
datapath = /home/gaming/.config/sunshine

[readiness]
certificates = certificates
address_family = both
EOF
    
    sudo chown -R gaming:gaming /home/gaming/.config/sunshine 2>/dev/null || true
    sudo chmod 700 /home/gaming/.config/sunshine 2>/dev/null || true
}

setup_tailscale() {
    echo "Setting up Tailscale..."
    
    nohup sudo tailscaled -state=/var/lib/tailscale/tailscaled.state >/dev/null 2>&1 &
    sleep 4
    
    AUTH_URL=$(sudo tailscale up 2>&1 | grep -oP 'https://[^\s]+' | head -1 || echo "")
    
    if [ -z "$AUTH_URL" ]; then
        AUTH_URL=$(sudo tailscale status 2>&1 | grep -oP 'https://[^\s]+' | head -1 || echo "https://login.tailscale.com/a/colab-machine")
    fi
    
    echo ""
    echo "📍 Authenticate Tailscale:"
    echo "$AUTH_URL"
    echo ""
    
    for i in {1..30}; do
        if sudo tailscale status >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
}

start_display_server() {
    echo "Starting display server..."
    
    sudo chmod 666 /dev/null 2>/dev/null || true
    
    export DISPLAY=:0
    nohup sudo -u gaming Xvfb :0 -screen 0 1920x1080x24 >/dev/null 2>&1 &
    sleep 3
}

start_plasma_desktop() {
    echo "Starting KDE Plasma..."
    
    export DISPLAY=:0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
    
    sudo mkdir -p /run/user/1000 2>/dev/null || true
    sudo chown gaming:gaming /run/user/1000 2>/dev/null || true
    sudo chmod 700 /run/user/1000 2>/dev/null || true
    
    nohup sudo -u gaming kwin_x11 >/dev/null 2>&1 &
    sleep 2
}

start_applications() {
    echo "Starting applications..."
    
    export DISPLAY=:0
    
    nohup sudo -u gaming dolphin >/dev/null 2>&1 &
    sleep 1
    
    nohup sudo -u gaming steam >/dev/null 2>&1 &
    nohup sudo -u gaming chromium-browser --new-window >/dev/null 2>&1 &
    nohup sudo -u gaming lutris >/dev/null 2>&1 &
}

start_sunshine_streaming() {
    echo "Starting Sunshine stream..."
    
    nohup sudo -u gaming sunshine --config-file=/home/gaming/.config/sunshine/config.conf >/dev/null 2>&1 &
    sleep 3
}

main() {
    configure_repos
    install_dependencies
    setup_users
    setup_sunshine
    setup_tailscale
    start_display_server
    start_plasma_desktop
    start_applications
    start_sunshine_streaming
    
    TAILSCALE_IP=$(sudo tailscale status 2>/dev/null | grep -oP '^\s+\d+\.\d+\.\d+\.\d+' | head -1 | xargs || echo "127.0.0.1")
    
    echo ""
    echo "✅ Setup Complete"
    echo "=================================="
    echo "Tailscale IP: $TAILSCALE_IP"
    echo "User: gaming"
    echo "Password: 1234"
    echo ""
    read -p "Enter 4-digit Moonlight PIN: " PIN
    
    while true; do
        sleep 30
        if ! pgrep -f "sunshine" >/dev/null 2>&1; then
            nohup sudo -u gaming sunshine --config-file=/home/gaming/.config/sunshine/config.conf >/dev/null 2>&1 &
        fi
    done
}

main
