#!/bin/bash

set -e

echo "🎮 Gaming Setup for Google Colab T4"
echo "===================================="

configure_repos() {
    echo "Configuring package repositories to USA..."
    sudo sed -i 's/archive.ubuntu.com/us.archive.ubuntu.com/g' /etc/apt/sources.list
    sudo sed -i 's/security.ubuntu.com/us.security.ubuntu.com/g' /etc/apt/sources.list
    sudo sed -i 's/ports.ubuntu.com/us.ports.ubuntu.com/g' /etc/apt/sources.list
    
    sudo apt-get update
    sudo apt-get upgrade -y
}

install_dependencies() {
    echo "Installing core dependencies..."
    sudo apt-get install -y \
        curl wget git \
        build-essential \
        mesa-utils \
        vulkan-tools \
        nvidia-cuda-toolkit

    echo "Installing Sunshine (streaming server)..."
    wget -q https://github.com/LizardByte/Sunshine/releases/download/v0.20.0/sunshine_0.20.0-1_amd64.deb
    sudo dpkg -i sunshine_0.20.0-1_amd64.deb || sudo apt-get install -y -f
    rm -f sunshine_0.20.0-1_amd64.deb

    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    echo "Installing gaming applications..."
    sudo apt-get install -y \
        lutris \
        chromium-browser \
        ark

    echo "Installing Steam..."
    sudo apt-get install -y steam-devices
    curl -fsSL https://repo.steampowered.com/steam/archive/stable/steam.gpg | sudo tee /usr/share/keyrings/steampowered-keyring.gpg > /dev/null
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/steampowered-keyring.gpg] http://repo.steampowered.com/steam/ stable steam" | sudo tee /etc/apt/sources.list.d/steampowered.list
    sudo apt-get update
    sudo apt-get install -y steam

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
        x11-common
}

setup_users() {
    echo "Setting up users..."
    
    if ! id -u gaming &>/dev/null; then
        sudo useradd -m -s /bin/bash -G sudo,video gaming
        echo "gaming:1234" | sudo chpasswd
        echo "Created user: gaming"
    fi

    echo "root:123456" | sudo chpasswd
    echo "Root password configured"
}

setup_sunshine() {
    echo "Configuring Sunshine..."
    
    SUNSHINE_CONFIG="/home/gaming/.config/sunshine/config.conf"
    mkdir -p /home/gaming/.config/sunshine
    
    cat > "$SUNSHINE_CONFIG" << 'EOF'
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
    
    sudo chown -R gaming:gaming /home/gaming/.config/sunshine
    sudo chmod 700 /home/gaming/.config/sunshine
}

setup_tailscale() {
    echo "Starting Tailscale..."
    
    nohup sudo tailscaled -state=/var/lib/tailscale/tailscaled.state >/dev/null 2>&1 &
    sleep 3
    
    AUTH_URL=$(sudo tailscale up 2>&1 | grep -oP 'https://\S+' | head -1)
    
    if [ -z "$AUTH_URL" ]; then
        AUTH_URL=$(sudo tailscale status 2>&1 | grep http || echo "Check Tailscale status manually")
    fi
    
    echo ""
    echo "📍 Authenticate Tailscale:"
    echo "$AUTH_URL"
    echo ""
    
    while ! sudo tailscale status &>/dev/null | grep -q "Healthy"; do
        sleep 2
    done
    
    TAILSCALE_IP=$(sudo tailscale status | grep -E "^\s+[0-9]" | head -1 | awk '{print $1}')
    echo "Tailscale IP: $TAILSCALE_IP"
}

start_display_server() {
    echo "Starting X11 display server..."
    
    sudo chmod 666 /dev/null
    
    export DISPLAY=:0
    nohup sudo -u gaming Xvfb :0 -screen 0 1920x1080x24 >/dev/null 2>&1 &
    sleep 3
}

start_plasma_desktop() {
    echo "Starting KDE Plasma..."
    
    export DISPLAY=:0
    export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
    
    mkdir -p /run/user/1000
    sudo chown gaming:gaming /run/user/1000
    sudo chmod 700 /run/user/1000
    
    nohup sudo -u gaming kwin_x11 >/dev/null 2>&1 &
    sleep 2
}

start_applications() {
    echo "Starting gaming applications..."
    
    export DISPLAY=:0
    
    nohup sudo -u gaming dolphin >/dev/null 2>&1 &
    sleep 1
    
    nohup sudo -u gaming steam >/dev/null 2>&1 &
    nohup sudo -u gaming chromium-browser --new-window >/dev/null 2>&1 &
    nohup sudo -u gaming lutris >/dev/null 2>&1 &
}

start_sunshine_streaming() {
    echo "Starting Sunshine streaming..."
    
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
    
    TAILSCALE_IP=$(sudo tailscale status | grep -E "^\s+[0-9]" | head -1 | awk '{print $1}' || echo "127.0.0.1")
    
    echo ""
    echo "✅ Setup Complete"
    echo "=================================="
    echo "Tailscale IP: $TAILSCALE_IP"
    echo "User: gaming"
    echo "Password: 1234"
    echo "Root Password: 123456"
    echo ""
    read -p "Enter 4-digit Moonlight pairing PIN: " PIN
    
    while true; do
        sleep 30
        if ! pgrep -f "sunshine" >/dev/null; then
            echo "Restarting Sunshine..."
            nohup sudo -u gaming sunshine --config-file=/home/gaming/.config/sunshine/config.conf >/dev/null 2>&1 &
        fi
    done
}

main
