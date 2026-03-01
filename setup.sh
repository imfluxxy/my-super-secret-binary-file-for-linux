#!/bin/bash
# if u break this dont blame me
set -e

# ─────────────────────────────────────────
# logging helpers – only show what matters
# ─────────────────────────────────────────
info()  { echo "[*] $*"; }
warn()  { echo "[!] $*"; }
die()   { echo "[x] $*"; exit 1; }

# swallow stdout but still show stderr on fail
quiet() {
    local tmp
    tmp=$(mktemp)
    if ! "$@" >"$tmp" 2>&1; then
        warn "command failed: $*"
        cat "$tmp"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

# ─────────────────────────────────────────
# detect os
# ─────────────────────────────────────────
detect_os() {
    [ -f /etc/os-release ] || die "can't detect OS, /etc/os-release missing"
    . /etc/os-release
    OS_ID="$ID"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="$VERSION_ID"
    OS_PRETTY="$PRETTY_NAME"

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "debian\|ubuntu"; then
        PKG_FAMILY="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -qi "rhel\|fedora\|centos\|rocky\|alma"; then
        PKG_FAMILY="redhat"
    else
        die "unknown os family: $OS_PRETTY"
    fi

    info "detected: $OS_PRETTY ($PKG_FAMILY)"
}

# ─────────────────────────────────────────
# us mirror fallback
# ─────────────────────────────────────────
fix_repos_debian() {
    info "swapping to US mirrors"
    if grep -qi "ubuntu" /etc/os-release; then
        sed -i 's|http://[^ ]*|http://us.archive.ubuntu.com/ubuntu|g' /etc/apt/sources.list
    else
        cat > /etc/apt/sources.list <<EOF
deb http://ftp.us.debian.org/debian/ $(lsb_release -cs) main contrib non-free non-free-firmware
deb http://ftp.us.debian.org/debian/ $(lsb_release -cs)-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $(lsb_release -cs)-security main contrib non-free
EOF
    fi
    quiet apt-get update -y
}

fix_repos_redhat() {
    info "swapping to US mirrors"
    sed -i 's|^metalink=|#metalink=|g; s|^#baseurl=|baseurl=|g' /etc/yum.repos.d/*.repo 2>/dev/null || true
    quiet dnf makecache --refresh -y 2>/dev/null || quiet yum makecache -y
}

# ─────────────────────────────────────────
# update system
# ─────────────────────────────────────────
update_system() {
    info "updating system..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        quiet apt-get update -y || { fix_repos_debian; quiet apt-get update -y; }
        quiet apt-get upgrade -y
    else
        quiet dnf upgrade -y 2>/dev/null || { fix_repos_redhat; quiet dnf upgrade -y; } 2>/dev/null || quiet yum upgrade -y
    fi
    info "system updated"
}

# ─────────────────────────────────────────
# install – debian
# ─────────────────────────────────────────
install_debian() {
    info "installing dependencies..."
    quiet apt-get install -y curl wget gpg ca-certificates software-properties-common apt-transport-https lsb-release

    # lutris
    info "installing lutris..."
    quiet apt-get install -y lutris || {
        quiet add-apt-repository ppa:lutris-team/lutris -y
        quiet apt-get update -y
        quiet apt-get install -y lutris
    }

    # tailscale
    info "installing tailscale..."
    if ! command -v tailscale &>/dev/null; then
        quiet sh -c "$(curl -fsSL https://tailscale.com/install.sh)"
    fi

    # moonlight
    info "installing moonlight..."
    quiet apt-get install -y moonlight-qt || {
        quiet apt-get install -y flatpak
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        quiet flatpak install -y flathub com.moonlight_stream.Moonlight
    }

    # sunshine – match exact ubuntu version to avoid glibc hell
    info "installing sunshine..."
    if ! command -v sunshine &>/dev/null; then
        RELEASE_JSON=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest)

        # exact version match first (e.g. ubuntu-22.04-amd64.deb)
        SUNSHINE_URL=$(echo "$RELEASE_JSON" \
            | grep browser_download_url \
            | grep "ubuntu-${OS_VERSION}-amd64\.deb" \
            | head -1 | cut -d '"' -f4)

        # fallback: oldest ubuntu deb available = lowest glibc req
        if [ -z "$SUNSHINE_URL" ]; then
            SUNSHINE_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'ubuntu.*amd64\.deb' \
                | sort | head -1 | cut -d '"' -f4)
        fi

        # last resort: AppImage (built on 22.04, works on glibc 2.35+)
        if [ -z "$SUNSHINE_URL" ]; then
            warn "no matching .deb, falling back to AppImage"
            SUNSHINE_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'sunshine\.AppImage' \
                | head -1 | cut -d '"' -f4)
            wget -qO /usr/local/bin/sunshine "$SUNSHINE_URL"
            chmod +x /usr/local/bin/sunshine
        else
            wget -qO /tmp/sunshine.deb "$SUNSHINE_URL"
            quiet apt-get install -y /tmp/sunshine.deb || quiet apt-get install -yf
            rm -f /tmp/sunshine.deb
        fi
    fi

    # chrome
    info "installing chrome..."
    if ! command -v google-chrome-stable &>/dev/null && ! command -v google-chrome &>/dev/null; then
        wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        quiet apt-get install -y /tmp/chrome.deb || quiet apt-get install -yf
        rm -f /tmp/chrome.deb
    fi

    # kde plasma 6 minimal
    info "installing kde plasma (minimal)..."
    quiet apt-get install -y \
        plasma-desktop dolphin konsole systemsettings sddm xorg xserver-xorg || {
        warn "some plasma packages missing, trying anyway"
        quiet apt-get install -y plasma-desktop dolphin konsole systemsettings sddm xorg || true
    }
    quiet apt-get install -y kde-config-emoji-picker 2>/dev/null || true
    quiet apt-get remove -y kwalletmanager kwallet-pam 2>/dev/null || true

    # bash (already there 99.9% of the time but whatever)
    quiet apt-get install -y bash

    # steam
    info "installing steam..."
    quiet dpkg --add-architecture i386
    quiet apt-get update -y
    quiet apt-get install -y steam-installer || quiet apt-get install -y steam || {
        quiet apt-get install -y flatpak 2>/dev/null || true
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        quiet flatpak install -y flathub com.valvesoftware.Steam
    }

    info "all packages installed"
}

# ─────────────────────────────────────────
# install – redhat
# ─────────────────────────────────────────
install_redhat() {
    info "installing dependencies..."
    quiet dnf install -y curl wget || quiet yum install -y curl wget

    # rpmfusion
    quiet dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null || \
    quiet dnf install -y \
        "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm" 2>/dev/null || true

    info "installing lutris..."
    quiet dnf install -y lutris || true

    info "installing tailscale..."
    command -v tailscale &>/dev/null || quiet sh -c "$(curl -fsSL https://tailscale.com/install.sh)"

    info "installing moonlight..."
    quiet dnf install -y moonlight-qt || {
        quiet dnf install -y flatpak
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        quiet flatpak install -y flathub com.moonlight_stream.Moonlight
    }

    info "installing sunshine..."
    if ! command -v sunshine &>/dev/null; then
        LATEST_RPM=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
            | grep browser_download_url | grep '\.rpm' | grep -v 'src' | head -1 | cut -d '"' -f4)
        wget -qO /tmp/sunshine.rpm "$LATEST_RPM"
        quiet dnf install -y /tmp/sunshine.rpm || rpm -i /tmp/sunshine.rpm 2>/dev/null
        rm -f /tmp/sunshine.rpm
    fi

    info "installing chrome..."
    if ! command -v google-chrome-stable &>/dev/null; then
        cat > /etc/yum.repos.d/google-chrome.repo <<EOF
[google-chrome]
name=google-chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
        quiet dnf install -y google-chrome-stable
    fi

    info "installing kde plasma (minimal)..."
    quiet dnf groupinstall -y "KDE Plasma Workspaces" --setopt=group_package_types=mandatory || \
        quiet dnf install -y plasma-desktop dolphin konsole kde-settings-plasma sddm xorg-x11-server-Xorg
    quiet dnf remove -y kwalletmanager 2>/dev/null || true

    quiet dnf install -y bash

    info "installing steam..."
    quiet dnf install -y steam || {
        quiet dnf install -y flatpak 2>/dev/null || true
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
        quiet flatpak install -y flathub com.valvesoftware.Steam
    }

    info "all packages installed"
}

# ─────────────────────────────────────────
# start daemon without systemd
# ─────────────────────────────────────────
start_daemon() {
    local name="$1"
    local cmd="$2"
    local pidfile="/tmp/${name}.pid"

    if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        info "$name already running (pid $(cat "$pidfile"))"
        return 0
    fi

    nohup $cmd >/tmp/${name}.log 2>&1 &
    echo $! > "$pidfile"
    info "$name started (pid $!)"
}

# ─────────────────────────────────────────
# tailscale – start daemon then auth
# ─────────────────────────────────────────
setup_tailscale() {
    info "starting tailscaled..."

    # check if systemd is actually running, use it if so, otherwise nohup it
    if pidof systemd >/dev/null 2>&1 || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        systemctl enable --now tailscaled 2>/dev/null || true
    else
        # no systemd, run it raw
        mkdir -p /var/run/tailscale /var/lib/tailscale
        start_daemon "tailscaled" "tailscaled --state=/var/lib/tailscale/tailscaled.state"
        sleep 2
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  tailscale needs auth – open the link"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tailscale up

    info "waiting for tailscale to connect..."
    while ! tailscale status 2>/dev/null | grep -q "^[0-9]"; do
        sleep 2
    done
    info "tailscale connected: $(tailscale ip -4)"
}

# ─────────────────────────────────────────
# sunshine – no password web ui
# ─────────────────────────────────────────
setup_sunshine() {
    info "configuring sunshine..."

    # find or create config
    SUNSHINE_CONF=""
    for path in \
        /etc/sunshine/sunshine.conf \
        /home/user/.config/sunshine/sunshine.conf \
        /root/.config/sunshine/sunshine.conf; do
        [ -f "$path" ] && SUNSHINE_CONF="$path" && break
    done

    if [ -z "$SUNSHINE_CONF" ]; then
        mkdir -p /home/user/.config/sunshine
        SUNSHINE_CONF="/home/user/.config/sunshine/sunshine.conf"
        touch "$SUNSHINE_CONF"
    fi

    # disable web ui auth on lan
    grep -q "origin_web_ui_allowed" "$SUNSHINE_CONF" \
        && sed -i 's/origin_web_ui_allowed.*/origin_web_ui_allowed = lan/' "$SUNSHINE_CONF" \
        || echo "origin_web_ui_allowed = lan" >> "$SUNSHINE_CONF"

    chown -R user:user /home/user/.config/sunshine 2>/dev/null || true

    # start sunshine without systemd
    if pidof systemd >/dev/null 2>&1 || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        systemctl enable --now sunshine 2>/dev/null || \
            su - user -c "systemctl --user enable --now sunshine 2>/dev/null" || true
    else
        # run as 'user' in background
        su - user -c "nohup sunshine >/tmp/sunshine.log 2>&1 & echo \$! > /tmp/sunshine.pid"
        info "sunshine started (pid $(cat /tmp/sunshine.pid 2>/dev/null || echo '?'))"
    fi

    sleep 2
    # set web ui creds
    sunshine --creds sunshine sunshine 2>/dev/null || true

    info "sunshine ready – web ui: https://localhost:47990 (sunshine/sunshine)"
}

# ─────────────────────────────────────────
# users
# ─────────────────────────────────────────
setup_users() {
    info "setting up users..."

    if ! id "user" &>/dev/null; then
        useradd -m -s /bin/bash user
    fi
    echo "user:1234" | chpasswd
    usermod -aG sudo user 2>/dev/null || usermod -aG wheel user 2>/dev/null || true
    usermod -aG input,video user 2>/dev/null || true

    echo "root:123456" | chpasswd
    info "users ready (user:1234, root:123456)"
}

# ─────────────────────────────────────────
# x11 + plasma config
# ─────────────────────────────────────────
setup_x11_permissions() {
    info "configuring x11 and plasma..."

    # xhost open for local – runs on any login
    cat > /etc/profile.d/xhost-local.sh <<'EOF'
#!/bin/bash
[ -n "$DISPLAY" ] && xhost +local: 2>/dev/null || true
EOF
    chmod +x /etc/profile.d/xhost-local.sh

    # kill kwallet prompts
    mkdir -p /home/user/.config
    cat > /home/user/.config/kwalletrc <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF

    # sddm autologin – try plasmax11 first, fallback to plasma
    mkdir -p /etc/sddm.conf.d
    SESSION="plasmax11.desktop"
    [ -f /usr/share/xsessions/plasmax11.desktop ] || SESSION="plasma.desktop"

    cat > /etc/sddm.conf.d/autologin.conf <<EOF
[Autologin]
User=user
Session=${SESSION}
Relogin=true
EOF

    chown -R user:user /home/user/.config
    info "x11 and autologin configured (session: $SESSION)"
}

# ─────────────────────────────────────────
# cleanup
# ─────────────────────────────────────────
cleanup() {
    info "cleaning up..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        quiet apt-get autoremove -y
        quiet apt-get autoclean -y
    else
        quiet dnf autoremove -y 2>/dev/null || quiet yum autoremove -y
    fi
    rm -f /tmp/sunshine.deb /tmp/sunshine.rpm /tmp/chrome.deb
    info "done"
}

# ─────────────────────────────────────────
# hold + launch plasma
# ─────────────────────────────────────────
finish_and_launch() {
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  setup done"
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

    info "starting plasma..."

    # try sddm first (with or without systemd)
    if pidof systemd >/dev/null 2>&1 || [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ]; then
        if systemctl is-active --quiet sddm; then
            info "sddm already running, autologin handles the rest"
        else
            systemctl enable --now sddm
        fi
    else
        # no systemd – start sddm directly or fall back to startx
        if command -v sddm &>/dev/null; then
            info "starting sddm directly"
            nohup sddm >/tmp/sddm.log 2>&1 &
            sleep 3
        else
            info "no sddm, starting X + plasma directly for user"
            su - user -c "nohup startx /usr/bin/startplasma-x11 -- :0 vt7 >/tmp/plasma.log 2>&1 &"
            sleep 5
        fi
        DISPLAY=:0 xhost +local: 2>/dev/null || true
    fi

    # restart sunshine to make sure it's grabbing the right display
    if command -v sunshine &>/dev/null; then
        su - user -c "nohup sunshine >/tmp/sunshine.log 2>&1 & echo \$! > /tmp/sunshine.pid" 2>/dev/null || true
    fi

    TS_IP=$(tailscale ip -4 2>/dev/null || echo "check tailscale status")
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  plasma is running for 'user'"
    echo "  tailscale ip: $TS_IP"
    echo "  add that ip in moonlight to connect"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─────────────────────────────────────────
# run
# ─────────────────────────────────────────
[ "$(id -u)" -ne 0 ] && die "run as root: sudo ./setup.sh"

detect_os
update_system

[ "$PKG_FAMILY" = "debian" ] && install_debian || install_redhat

setup_users
setup_tailscale
setup_sunshine
setup_x11_permissions
cleanup
finish_and_launch
