#!/bin/bash
# if u break this dont blame me

# no set -e – we handle failures ourselves so one missing optional package
# doesn't nuke the whole thing. quiet() shows output only on real failures.
set -uo pipefail

info() { echo "[*] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*"; exit 1; }

# run a command silently, only dump output if it actually fails
# returns the real exit code so callers can decide what to do with it
quiet() {
    local tmp rc
    tmp=$(mktemp)
    "$@" >"$tmp" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "failed (exit $rc): $*"
        cat "$tmp"
    fi
    rm -f "$tmp"
    return "$rc"
}

# same but kills the script on failure
quiet_required() {
    quiet "$@" || die "required step failed, can't continue"
}

# ─────────────────────────────────────────
# detect os
# ─────────────────────────────────────────
detect_os() {
    [ -f /etc/os-release ] || die "can't detect OS – /etc/os-release missing"
    . /etc/os-release
    OS_ID="$ID"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-}"
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
    quiet dnf makecache --refresh -y 2>/dev/null || quiet yum makecache -y || true
}

# ─────────────────────────────────────────
# update system
# ─────────────────────────────────────────
update_system() {
    info "updating system..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        quiet apt-get update -y || { fix_repos_debian; quiet_required apt-get update -y; }
        quiet apt-get upgrade -y || true
    else
        quiet dnf upgrade -y || { fix_repos_redhat; quiet dnf upgrade -y; } || quiet yum upgrade -y || true
    fi
    info "system updated"
}

# ─────────────────────────────────────────
# install – debian/ubuntu
# ─────────────────────────────────────────
install_debian() {
    info "installing base dependencies..."
    quiet_required apt-get install -y curl wget gpg ca-certificates \
        software-properties-common apt-transport-https lsb-release

    info "installing lutris..."
    quiet apt-get install -y lutris || {
        quiet add-apt-repository ppa:lutris-team/lutris -y
        quiet apt-get update -y
        quiet apt-get install -y lutris
    } || warn "lutris install failed, skipping"

    info "installing tailscale..."
    if ! command -v tailscale &>/dev/null; then
        quiet sh -c "$(curl -fsSL https://tailscale.com/install.sh)" || \
            die "tailscale install failed – needed for this setup"
    fi

    info "installing moonlight..."
    quiet apt-get install -y moonlight-qt || {
        quiet apt-get install -y flatpak
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        quiet flatpak install -y flathub com.moonlight_stream.Moonlight
    } || warn "moonlight install failed, skipping"

    info "installing sunshine..."
    if ! command -v sunshine &>/dev/null; then
        RELEASE_JSON=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest)

        # try exact ubuntu version match first to dodge the glibc 2.38 trap
        SUNSHINE_URL=$(echo "$RELEASE_JSON" \
            | grep browser_download_url \
            | grep "ubuntu-${OS_VERSION}-amd64\.deb" \
            | head -1 | cut -d '"' -f4)

        # fallback: oldest ubuntu deb = lowest glibc requirement
        if [ -z "$SUNSHINE_URL" ]; then
            SUNSHINE_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'ubuntu.*amd64\.deb' \
                | sort | head -1 | cut -d '"' -f4)
        fi

        if [ -n "$SUNSHINE_URL" ]; then
            wget -qO /tmp/sunshine.deb "$SUNSHINE_URL"
            quiet apt-get install -y /tmp/sunshine.deb || quiet apt-get install -yf || true
            rm -f /tmp/sunshine.deb
        else
            # AppImage fallback – compiled on 22.04, glibc 2.35 is enough
            warn "no matching .deb, falling back to AppImage"
            APPIMG_URL=$(echo "$RELEASE_JSON" \
                | grep browser_download_url \
                | grep 'sunshine\.AppImage' \
                | head -1 | cut -d '"' -f4)
            wget -qO /usr/local/bin/sunshine "$APPIMG_URL"
            chmod +x /usr/local/bin/sunshine
        fi
    fi

    info "installing chrome..."
    if ! command -v google-chrome-stable &>/dev/null && ! command -v google-chrome &>/dev/null; then
        wget -qO /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        quiet apt-get install -y /tmp/chrome.deb || quiet apt-get install -yf || warn "chrome failed"
        rm -f /tmp/chrome.deb
    fi

    info "installing kde plasma (minimal)..."
    quiet apt-get install -y \
        plasma-desktop dolphin konsole systemsettings sddm xorg xserver-xorg \
        || quiet apt-get install -y plasma-desktop dolphin konsole systemsettings sddm xorg \
        || warn "some plasma packages missing"
    quiet apt-get install -y kde-config-emoji-picker || true

    # kwallet – optional remove, who cares if it's not installed
    apt-get remove -y kwalletmanager 2>/dev/null || true
    apt-get remove -y kwallet-pam    2>/dev/null || true

    quiet apt-get install -y bash

    info "installing steam..."
    quiet dpkg --add-architecture i386 || true
    quiet apt-get update -y || true
    quiet apt-get install -y steam-installer \
        || quiet apt-get install -y steam \
        || {
            quiet apt-get install -y flatpak || true
            quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
            quiet flatpak install -y flathub com.valvesoftware.Steam || warn "steam install failed"
        }

    info "all packages done"
}

# ─────────────────────────────────────────
# install – redhat/fedora
# ─────────────────────────────────────────
install_redhat() {
    info "installing base dependencies..."
    quiet dnf install -y curl wget || quiet yum install -y curl wget

    quiet dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm" 2>/dev/null \
    || quiet dnf install -y \
        "https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-$(rpm -E %rhel).noarch.rpm" 2>/dev/null \
    || warn "rpmfusion setup failed, some packages may not be available"

    info "installing lutris..."
    quiet dnf install -y lutris || warn "lutris not found, skipping"

    info "installing tailscale..."
    command -v tailscale &>/dev/null || \
        quiet sh -c "$(curl -fsSL https://tailscale.com/install.sh)" || \
        die "tailscale install failed"

    info "installing moonlight..."
    quiet dnf install -y moonlight-qt || {
        quiet dnf install -y flatpak
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        quiet flatpak install -y flathub com.moonlight_stream.Moonlight
    } || warn "moonlight failed, skipping"

    info "installing sunshine..."
    if ! command -v sunshine &>/dev/null; then
        LATEST_RPM=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest \
            | grep browser_download_url | grep '\.rpm' | grep -v 'src' | head -1 | cut -d '"' -f4)
        wget -qO /tmp/sunshine.rpm "$LATEST_RPM"
        quiet dnf install -y /tmp/sunshine.rpm || rpm -i /tmp/sunshine.rpm 2>/dev/null || warn "sunshine install failed"
        rm -f /tmp/sunshine.rpm
    fi

    info "installing chrome..."
    if ! command -v google-chrome-stable &>/dev/null; then
        cat > /etc/yum.repos.d/google-chrome.repo <<'EOF'
[google-chrome]
name=google-chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
        quiet dnf install -y google-chrome-stable || warn "chrome failed"
    fi

    info "installing kde plasma (minimal)..."
    quiet dnf groupinstall -y "KDE Plasma Workspaces" --setopt=group_package_types=mandatory \
        || quiet dnf install -y plasma-desktop dolphin konsole kde-settings-plasma sddm xorg-x11-server-Xorg \
        || warn "some kde packages failed"
    quiet dnf remove -y kwalletmanager 2>/dev/null || true
    quiet dnf install -y bash || true

    info "installing steam..."
    quiet dnf install -y steam || {
        quiet dnf install -y flatpak || true
        quiet flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
        quiet flatpak install -y flathub com.valvesoftware.Steam || warn "steam failed"
    }

    info "all packages done"
}

# ─────────────────────────────────────────
# check if systemd is actually running as pid1
# ─────────────────────────────────────────
has_systemd() {
    [ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] || pidof systemd >/dev/null 2>&1
}

# ─────────────────────────────────────────
# tailscale – bring up daemon then authenticate
# ─────────────────────────────────────────
setup_tailscale() {
    info "starting tailscaled..."

    # kill any stale instance first
    pkill -f tailscaled 2>/dev/null || true
    sleep 1

    if has_systemd; then
        systemctl enable --now tailscaled 2>/dev/null || true
    else
        mkdir -p /var/run/tailscale /var/lib/tailscale
        tailscaled --state=/var/lib/tailscale/tailscaled.state </dev/null >/tmp/tailscaled.log 2>&1 &
        TDPID=$!
        disown "$TDPID"
        echo "$TDPID" > /tmp/tailscaled.pid
        info "tailscaled started as daemon (pid $TDPID)"
    fi

    # poll until socket responds – give it up to 30s
    info "waiting for tailscaled socket..."
    for i in $(seq 1 30); do
        tailscale status >/dev/null 2>&1 && break
        sleep 1
    done
    tailscale status >/dev/null 2>&1 || die "tailscaled still not up after 30s – check /tmp/tailscaled.log"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  tailscale needs auth – open the link"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tailscale up

    info "waiting for tailscale to be connected..."
    while ! tailscale status 2>/dev/null | grep -q "^[0-9]"; do
        sleep 2
    done
    info "tailscale connected: $(tailscale ip -4)"
}

# ─────────────────────────────────────────
# sunshine – no password web ui + pin pairing helper
# ─────────────────────────────────────────
setup_sunshine() {
    info "configuring sunshine..."

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

    # open web ui without password on LAN
    grep -q "origin_web_ui_allowed" "$SUNSHINE_CONF" \
        && sed -i 's/origin_web_ui_allowed.*/origin_web_ui_allowed = lan/' "$SUNSHINE_CONF" \
        || echo "origin_web_ui_allowed = lan" >> "$SUNSHINE_CONF"

    chown -R user:user /home/user/.config/sunshine 2>/dev/null || true

    # start sunshine
    if has_systemd; then
        systemctl enable --now sunshine 2>/dev/null \
            || su - user -c "systemctl --user enable --now sunshine 2>/dev/null" \
            || true
    else
        pkill -f "^sunshine" 2>/dev/null || true
        sleep 1
        su - user -c "nohup sunshine >/tmp/sunshine.log 2>&1 & echo \$! > /tmp/sunshine.pid"
        info "sunshine started (pid $(cat /tmp/sunshine.pid 2>/dev/null || echo '?'))"
    fi

    sleep 3
    # set web ui credentials
    sunshine --creds sunshine sunshine 2>/dev/null || true

    info "sunshine ready"
}

# wait for sunshine web ui to be up then submit the pairing pin
submit_sunshine_pin() {
    local pin="$1"
    local max=20
    local i

    info "waiting for sunshine web ui..."
    for i in $(seq 1 $max); do
        if curl -sk https://localhost:47990 >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    info "submitting pin $pin to sunshine..."
    RESPONSE=$(curl -sk -X POST https://localhost:47990/api/pin \
        -u "sunshine:sunshine" \
        -H "Content-Type: application/json" \
        -d "{\"pin\":\"$pin\",\"name\":\"paired-client\"}" 2>&1)

    if echo "$RESPONSE" | grep -qi "success\|true"; then
        info "pin accepted – pairing done"
    else
        warn "pin response: $RESPONSE"
        warn "if that looks wrong, go to https://localhost:47990/pin manually"
    fi
}

# ─────────────────────────────────────────
# create users
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
    info "users ready (user:1234 | root:123456)"
}

# ─────────────────────────────────────────
# x11 + plasma config
# ─────────────────────────────────────────
setup_x11_permissions() {
    info "configuring x11 and plasma..."

    cat > /etc/profile.d/xhost-local.sh <<'EOF'
#!/bin/bash
[ -n "$DISPLAY" ] && xhost +local: 2>/dev/null || true
EOF
    chmod +x /etc/profile.d/xhost-local.sh

    # disable kwallet nag popups
    mkdir -p /home/user/.config
    cat > /home/user/.config/kwalletrc <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF

    # sddm autologin for 'user'
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
    info "x11 and autologin set (session: $SESSION)"
}

# ─────────────────────────────────────────
# cleanup
# ─────────────────────────────────────────
cleanup() {
    info "cleaning up..."
    if [ "$PKG_FAMILY" = "debian" ]; then
        quiet apt-get autoremove -y || true
        quiet apt-get autoclean -y  || true
    else
        quiet dnf autoremove -y 2>/dev/null || quiet yum autoremove -y || true
    fi
    rm -f /tmp/sunshine.deb /tmp/sunshine.rpm /tmp/chrome.deb
    info "cleanup done"
}

# ─────────────────────────────────────────
# final – show info, ask for pin, start plasma
# ─────────────────────────────────────────
finish_and_launch() {
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  setup done"
    echo ""
    echo "  tailscale ip  : $TS_IP"
    echo "  sunshine ui   : https://localhost:47990"
    echo "                  creds: sunshine / sunshine"
    echo "  session user  : user / 1234"
    echo "  root pw       : 123456"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # ask for sunshine pairing pin before starting plasma
    # (open moonlight, add the tailscale ip, it'll show a 4-digit pin)
    echo "  open moonlight now and add: $TS_IP"
    echo "  it will show a 4-digit pairing PIN"
    echo ""
    while true; do
        printf "  enter the 4-digit pin from moonlight (or press ENTER to skip): "
        read -r PIN
        if [ -z "$PIN" ]; then
            info "skipping pin pairing"
            break
        elif echo "$PIN" | grep -qE '^[0-9]{4}$'; then
            submit_sunshine_pin "$PIN"
            break
        else
            warn "pin should be exactly 4 digits, try again"
        fi
    done

    echo ""
    printf "  press ENTER to start plasma for 'user' (ctrl+c to bail): "
    read -r _

    info "starting plasma..."

    if has_systemd; then
        if systemctl is-active --quiet sddm; then
            info "sddm already running – autologin handles the rest"
        else
            systemctl enable --now sddm
        fi
    else
        if command -v sddm &>/dev/null; then
            info "starting sddm directly"
            nohup sddm >/tmp/sddm.log 2>&1 &
            disown
            sleep 3
        else
            info "no sddm, starting X + plasma directly"
            su - user -c "nohup startx /usr/bin/startplasma-x11 -- :0 vt7 >/tmp/plasma.log 2>&1 &"
            sleep 5
        fi
        DISPLAY=:0 xhost +local: 2>/dev/null || true
    fi

    # make sure sunshine restarts with the display available
    pkill -f "^sunshine" 2>/dev/null || true
    sleep 2
    su - user -c "DISPLAY=:0 nohup sunshine >/tmp/sunshine.log 2>&1 & echo \$! > /tmp/sunshine.pid" 2>/dev/null || true

    TS_IP=$(tailscale ip -4 2>/dev/null || echo "check tailscale status")
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  plasma is live for 'user'"
    echo "  tailscale ip  : $TS_IP"
    echo "  connect via moonlight using that ip"
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
