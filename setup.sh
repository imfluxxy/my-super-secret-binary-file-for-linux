#!/bin/bash
# if u break this dont blame me
set -e

# ─────────────────────────────────────────
# detect os
# ─────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_ID_LIKE="$ID_LIKE"
        OS_VERSION="$VERSION_ID"
        OS_PRETTY="$PRETTY_NAME"
    else
        echo "[!] can't detect OS, /etc/os-release missing. are you on windows or something"
        exit 1
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "debian\|ubuntu"; then
        PKG_FAMILY="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -qi "rhel\|fedora\|centos\|rocky\|alma"; then
        PKG_FAMILY="redhat"
    else
        echo "[!] unknown os family: $OS_PRETTY"
        exit 1
    fi

    echo "[*] detected: $OS_PRETTY ($PKG_FAMILY)"
}

# ─────────────────────────────────────────
# update repos to us mirrors if something fails
# ─────────────────────────────────────────
fix_repos_debian() {
    echo "[*] swapping to US mirrors (debian/ubuntu)"
    if grep -qi "ubuntu" /etc/os-release; then
        sed -i 's|http://[^ ]*|http://us.archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
    else
        # debian
        cat > /etc/apt/sources.list <<EOF
deb http://ftp.us.debian.org/debian/ $(lsb_release -cs) main contrib non-free non-free-firmware
deb http://ftp.us.debian.org/debian/ $(lsb_release -cs)-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $(lsb_release -cs)-security main contrib non-free
EOF
    fi
    apt-get update -y
}

fix_repos_redhat() {
    echo "[*] swapping to US mirrors (redhat family)"
    if command -v dnf &>/dev/null; then
        sed -i 's|^metalink=|#metalink=|g; s|^#baseurl=|baseurl=|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
        sed -i 's|download\.fedoraproject\.org|dl.fedoraproject.org|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
    fi
    dnf makecache --refresh -y 2>/dev/null || yum makecache -y
}

# ─────────────────────────────────────────
# update system
# ─────────────────────────────────────────
update_system() {
    echo "[*] updating system..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        apt-get update -y || { fix_repos_debian; apt-get update -y; }
        apt-get upgrade -y
    else
        dnf upgrade -y 2>/dev/null || { fix_repos_redhat; dnf upgrade -y; } 2>/dev/null || yum upgrade -y
    fi
}

# ─────────────────────────────────────────
# install all the stuff
# ─────────────────────────────────────────
install_debian() {
    echo "[*] installing packages (debian/ubuntu)"

    apt-get install -y curl wget gpg ca-certificates software-properties-common apt-transport-https lsb-release

    # lutris
    apt-get install -y lutris || {
        echo "[*] lutris not in default repo, trying ppa"
        add-apt-repository ppa:lutris-team/lutris -y && apt-get update -y && apt-get install -y lutris
    }

    # tailscale
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # moonlight
    if ! command -v moonlight-qt &>/dev/null; then
        apt-get install -y moonlight-qt || {
            # flatpak fallback bc moonlight loves doing this
            apt-get install -y flatpak
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            flatpak install -y flathub com.moonlight_stream.Moonlight
        }
    fi

    # sunshine – grab the right deb for this ubuntu version
    if ! command -v sunshine &>/dev/null; then
        RELEASE_JSON=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest)

        # try to match exact ubuntu version first (e.g. ubuntu-22.04)
        SUNSHINE_URL=$(echo "$RELEASE_JSON" \
            | grep browser_download_url \
            | grep "ubuntu-${OS_VERSION}-amd64\.deb" \
            | head -1 | cut -d '"' -f4)

        # fallback: any ubuntu deb (prefer lower version = older glibc req)
        if [ -z "$SUNSHINE_URL" ]; then
            SUNSHINE_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'ubuntu.*amd64\.deb' \
                | sort | head -1 | cut -d '"' -f4)
        fi

        # last resort fallback: AppImage (built on 22.04, needs glibc 2.35+ which jammy has)
        if [ -z "$SUNSHINE_URL" ]; then
            echo "[*] no matching .deb found, falling back to AppImage"
            SUNSHINE_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'sunshine\.AppImage' \
                | head -1 | cut -d '"' -f4)
            wget -qO /usr/local/bin/sunshine "$SUNSHINE_URL"
            chmod +x /usr/local/bin/sunshine
            # create a systemd service for it manually
            cat > /etc/systemd/system/sunshine.service <<'EOF'
[Unit]
Description=Sunshine self-hosted game stream host for Moonlight
After=network.target

[Service]
ExecStart=/usr/local/bin/sunshine
Restart=on-failure
User=user

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
        else
            wget -qO /tmp/sunshine.deb "$SUNSHINE_URL"
            apt-get install -y /tmp/sunshine.deb || apt-get install -yf
            rm -f /tmp/sunshine.deb
        fi
    fi

    # chrome
    if ! command -v google-chrome-stable &>/dev/null && ! command -v google-chrome &>/dev/null; then
        wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        apt-get install -y /tmp/chrome.deb || apt-get install -yf
        rm -f /tmp/chrome.deb
    fi

    # kde plasma 6 – basic apps only, no bloat
    apt-get install -y \
        plasma-desktop \
        dolphin \
        konsole \
        systemsettings \
        sddm \
        xorg \
        xserver-xorg || {
            echo "[!] some kde packages might have different names, trying alternatives"
            apt-get install -y plasma-desktop dolphin konsole systemsettings sddm xorg || true
        }

    # emoji picker for kde
    apt-get install -y kde-config-emoji-picker 2>/dev/null || true

    # kill kwallet – nobody asked for this thing
    apt-get remove -y kwalletmanager kwallet-pam 2>/dev/null || true

    # bash
    apt-get install -y bash

    # steam
    dpkg --add-architecture i386
    apt-get update -y
    apt-get install -y steam-installer || apt-get install -y steam || {
        echo "[*] steam not in repo, flatpak time"
        apt-get install -y flatpak 2>/dev/null || true
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        flatpak install -y flathub com.valvesoftware.Steam
    }
}

install_redhat() {
    echo "[*] installing packages (redhat/fedora)"

    dnf install -y curl wget || yum install -y curl wget

    # rpmfusion so we can actually install stuff
    dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null || \
    dnf install -y \
        "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm" 2>/dev/null || true

    dnf install -y lutris || true

    # tailscale
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # moonlight
    dnf install -y moonlight-qt || {
        dnf install -y flatpak
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak install -y flathub com.moonlight_stream.Moonlight
    }

    # sunshine
    if ! command -v sunshine &>/dev/null; then
        LATEST_RPM=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
            | grep browser_download_url | grep '\.rpm' | grep -v 'src' | head -1 | cut -d '"' -f4)
        wget -qO /tmp/sunshine.rpm "$LATEST_RPM"
        dnf install -y /tmp/sunshine.rpm || rpm -i /tmp/sunshine.rpm
        rm -f /tmp/sunshine.rpm
    fi

    # chrome
    if ! command -v google-chrome-stable &>/dev/null; then
        cat > /etc/yum.repos.d/google-chrome.repo <<EOF
[google-chrome]
name=google-chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
        dnf install -y google-chrome-stable
    fi

    # kde plasma 6 – mandatory packages only
    dnf groupinstall -y "KDE Plasma Workspaces" --setopt=group_package_types=mandatory || \
        dnf install -y plasma-desktop dolphin konsole kde-settings-plasma sddm xorg-x11-server-Xorg

    # no kwallet thx
    dnf remove -y kwalletmanager 2>/dev/null || true

    dnf install -y bash

    # steam
    dnf install -y steam || {
        dnf install -y flatpak 2>/dev/null || true
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        flatpak install -y flathub com.valvesoftware.Steam
    }
}

# ─────────────────────────────────────────
# tailscale auth – block until authenticated
# ─────────────────────────────────────────
setup_tailscale() {
    echo "[*] enabling and starting tailscale..."
    systemctl enable --now tailscaled

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  tailscale needs auth"
    echo "  open the link below in your browser"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tailscale up

    echo "[*] waiting for tailscale to connect..."
    while ! tailscale status 2>/dev/null | grep -q "^[0-9]"; do
        sleep 2
    done
    echo "[*] tailscale connected: $(tailscale ip -4)"
}

# ─────────────────────────────────────────
# sunshine – no password on web ui
# streaming pairing still needs a pin on first moonlight connect, that's normal
# ─────────────────────────────────────────
setup_sunshine() {
    echo "[*] setting up sunshine..."

    # start it first so config dirs get created
    systemctl enable --now sunshine 2>/dev/null || \
        sudo -u "${SUDO_USER:-user}" bash -c "systemctl --user enable --now sunshine 2>/dev/null" || true

    sleep 3

    # set web ui credentials to basically nothing
    sunshine --creds sunshine sunshine 2>/dev/null || true

    # find config file wherever it landed
    SUNSHINE_CONF=""
    for path in \
        /etc/sunshine/sunshine.conf \
        /root/.config/sunshine/sunshine.conf \
        /home/user/.config/sunshine/sunshine.conf; do
        [ -f "$path" ] && SUNSHINE_CONF="$path" && break
    done

    if [ -z "$SUNSHINE_CONF" ]; then
        mkdir -p /home/user/.config/sunshine
        SUNSHINE_CONF="/home/user/.config/sunshine/sunshine.conf"
        touch "$SUNSHINE_CONF"
    fi

    # disable web ui password prompt on lan
    grep -q "origin_web_ui_allowed" "$SUNSHINE_CONF" \
        && sed -i 's/origin_web_ui_allowed.*/origin_web_ui_allowed = lan/' "$SUNSHINE_CONF" \
        || echo "origin_web_ui_allowed = lan" >> "$SUNSHINE_CONF"

    chown user:user "$SUNSHINE_CONF" 2>/dev/null || true

    echo "[*] sunshine ready (web ui at https://localhost:47990, creds: sunshine/sunshine)"
}

# ─────────────────────────────────────────
# create sudo 'user' account + set root pw
# ─────────────────────────────────────────
setup_users() {
    echo "[*] setting up users..."

    if ! id "user" &>/dev/null; then
        useradd -m -s /bin/bash user
    fi

    echo "user:1234" | chpasswd
    # add to sudo group (debian) or wheel (redhat)
    usermod -aG sudo user 2>/dev/null || usermod -aG wheel user 2>/dev/null || true

    # sunshine needs these
    usermod -aG input user 2>/dev/null || true
    usermod -aG video user 2>/dev/null || true

    echo "root:123456" | chpasswd

    echo "[*] 'user':1234 created, root:123456 set"
}

# ─────────────────────────────────────────
# x11 perms so plasma runs fine under 'user'
# and sunshine can grab the display
# ─────────────────────────────────────────
setup_x11_permissions() {
    echo "[*] configuring x11 and plasma..."

    # xhost open for local connections – runs on login
    cat > /etc/profile.d/xhost-local.sh <<'EOF'
#!/bin/bash
# needed so sunshine can grab the x display
if [ -n "$DISPLAY" ]; then
    xhost +local: 2>/dev/null || true
fi
EOF
    chmod +x /etc/profile.d/xhost-local.sh

    # disable kwallet popup at login – this thing is annoying as hell
    mkdir -p /home/user/.config
    cat > /home/user/.config/kwalletrc <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF

    # sddm autologin into plasma x11 for 'user'
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/autologin.conf <<'EOF'
[Autologin]
User=user
Session=plasmax11.desktop
Relogin=true
EOF

    # if plasmax11.desktop doesn't exist, try plain plasma.desktop
    if [ ! -f /usr/share/xsessions/plasmax11.desktop ]; then
        sed -i 's/plasmax11.desktop/plasma.desktop/' /etc/sddm.conf.d/autologin.conf
    fi

    chown -R user:user /home/user/.config

    echo "[*] x11 + autologin configured"
}

# ─────────────────────────────────────────
# cleanup temp junk
# ─────────────────────────────────────────
cleanup() {
    echo "[*] cleaning up..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        apt-get autoremove -y
        apt-get autoclean -y
    else
        dnf autoremove -y 2>/dev/null || yum autoremove -y
    fi
    rm -f /tmp/sunshine.deb /tmp/sunshine.rpm /tmp/chrome.deb
    echo "[*] cleanup done"
}

# ─────────────────────────────────────────
# hold script, show ip, launch plasma
# ─────────────────────────────────────────
finish_and_launch() {
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown (check tailscale status)")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  everything's set up"
    echo ""
    echo "  tailscale ip  : $TS_IP"
    echo "  sunshine ui   : https://localhost:47990"
    echo "                  user: sunshine / pw: sunshine"
    echo "  session user  : user / 1234"
    echo "  root pw       : 123456"
    echo ""
    echo "  press ENTER to start plasma for 'user'"
    echo "  ctrl+c to stop here"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    read -r _

    echo "[*] starting plasma..."

    if systemctl is-active --quiet sddm; then
        echo "[*] sddm already up, autologin should handle the rest"
    else
        systemctl enable --now sddm
    fi

    # if no display yet (headless/tty), start x for user manually
    if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
        echo "[*] headless mode – starting xorg + plasma for user"
        su - user -c "startx /usr/bin/startplasma-x11 -- :0 vt7" &
        sleep 5
        DISPLAY=:0 xhost +local: 2>/dev/null || true
    fi

    # make sure sunshine is running
    systemctl restart sunshine 2>/dev/null || \
        su - user -c "systemctl --user restart sunshine 2>/dev/null" || true

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  plasma is running for 'user'"
    echo "  tailscale ip: $TS_IP"
    echo "  connect via moonlight using that ip"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─────────────────────────────────────────
# run
# ─────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "[!] gotta run this as root: sudo ./setup.sh"
    exit 1
fi

detect_os
update_system

if [ "$PKG_FAMILY" = "debian" ]; then
    install_debian
else
    install_redhat
fi

setup_users
setup_tailscale
setup_sunshine
setup_x11_permissions
cleanup
finish_and_launch
