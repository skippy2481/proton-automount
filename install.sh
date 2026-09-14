#!/usr/bin/env bash
# Proton Automount — dependency installer
# Works three ways:
#   • KDE popup mode (kdialog)     — e.g. launched from Dolphin/file manager
#   • GNOME/other popup (zenity)   — any desktop with zenity installed
#   • Plain terminal mode          — no dialog tool, prints to stdout
#
# Detects the package manager (dnf/apt/pacman/zypper) automatically.
# Root elevation: sudo when a terminal is attached, pkexec (graphical
# password prompt) when launched from a file manager with no terminal.

# --- Detect dialog tool -------------------------------------------------------
if command -v kdialog >/dev/null 2>&1; then
    DLG="kdialog"
elif command -v zenity >/dev/null 2>&1; then
    DLG="zenity"
else
    DLG=""
fi

# --- Detect whether a terminal is attached -------------------------------------
if [ -t 0 ]; then
    HAVE_TERM="yes"
else
    HAVE_TERM="no"
fi

# --- Dialog helpers (dispatch to whatever is available) -------------------------
msg_box() {  # $1=title  $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --msgbox "$2" ;;
        zenity)  zenity --info --title="$1" --text="$2" >/dev/null 2>&1 ;;
        *)       echo "── $1 ──"; echo "$2" ;;
    esac
}

error_box() {  # $1=title  $2=text  (always exits 1)
    case "$DLG" in
        kdialog) kdialog --title "$1" --error "$2" ;;
        zenity)  zenity --error --title="$1" --text="$2" >/dev/null 2>&1 ;;
        *)       echo "ERROR: $1" >&2; echo "$2" >&2 ;;
    esac
    exit 1
}

ask_box() {  # $1=title  $2=text  (returns 0 = yes, 1 = no)
    case "$DLG" in
        kdialog) kdialog --title "$1" --yesno "$2" ;;
        zenity)  zenity --question --title="$1" --text="$2" >/dev/null 2>&1 ;;
        *)       local a; read -rp "$2 [y/N] " a
                 [ "$a" = "y" ] || [ "$a" = "Y" ] ;;
    esac
}

# --- Root elevation -------------------------------------------------------------
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif [ "$HAVE_TERM" = "yes" ] && command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    else
        error_box "Proton Drive Installer" \
"Root privileges are required to install packages, but neither sudo
(nor pkexec for graphical elevation) is available.

Install the dependencies manually, then run this installer again."
    fi
}

# --- Detect package manager ------------------------------------------------------
if command -v dnf >/dev/null 2>&1; then
    PKGMGR="dnf"
    PKG_RCLONE="rclone" PKG_FUSE="fuse3" PKG_YK="yubikey-manager" PKG_NOTIFY="libnotify"
elif command -v apt-get >/dev/null 2>&1; then
    PKGMGR="apt"
    PKG_RCLONE="rclone" PKG_FUSE="fuse3" PKG_YK="yubikey-manager" PKG_NOTIFY="libnotify-bin"
elif command -v pacman >/dev/null 2>&1; then
    PKGMGR="pacman"
    PKG_RCLONE="rclone" PKG_FUSE="fuse3" PKG_YK="yubikey-manager" PKG_NOTIFY=""
elif command -v zypper >/dev/null 2>&1; then
    PKGMGR="zypper"
    PKG_RCLONE="rclone" PKG_FUSE="fuse" PKG_YK="yubikey-manager" PKG_NOTIFY=""
else
    error_box "Proton Drive Installer" \
"No supported package manager found (dnf / apt / pacman / zypper).

Please install the dependencies manually:
rclone (>= 1.64), fuse3, yubikey-manager (ykman), libnotify."
fi

if [ "$HAVE_TERM" = "yes" ]; then
    echo "=== Proton Drive Auto-Mount Installer ==="
    echo "Package manager: $PKGMGR   Dialog: ${DLG:-terminal}"
fi

# --- Check for ANY usable dialog tool --------------------------------------------
# Without one, the mount script itself cannot show its 2FA popups.
if [ -z "$DLG" ]; then
    error_box "Proton Drive Installer" \
"No dialog tool found (kdialog or zenity).

This project needs one for its login/2FA popups:
• KDE Plasma:  $PKGMGR install kdialog
• GNOME/other: $PKGMGR install zenity

Install one, then run this installer again."
fi

# --- Build the dependency list (only what's missing) ------------------------------
PKGS_TO_INSTALL=""

command -v rclone     >/dev/null 2>&1 || PKGS_TO_INSTALL+=" $PKG_RCLONE"
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || PKGS_TO_INSTALL+=" $PKG_FUSE"
command -v ykman      >/dev/null 2>&1 || PKGS_TO_INSTALL+=" $PKG_YK"
command -v notify-send >/dev/null 2>&1 || [ -z "$PKG_NOTIFY" ] || PKGS_TO_INSTALL+=" $PKG_NOTIFY"

# --- Install missing dependencies -------------------------------------------------
if [ -z "$PKGS_TO_INSTALL" ]; then
    [ "$HAVE_TERM" = "yes" ] && echo "✓ All dependencies already installed."
else
    [ "$HAVE_TERM" = "yes" ] && echo "Installing:$PKGS_TO_INSTALL"

    case "$PKGMGR" in
        dnf)    as_root dnf    install -y $PKGS_TO_INSTALL ;;
        apt)    as_root apt-get update
                as_root apt-get install -y $PKGS_TO_INSTALL ;;
        pacman) as_root pacman -Sy --noconfirm $PKGS_TO_INSTALL ;;
        zypper) as_root zypper install -y $PKGS_TO_INSTALL ;;
    esac

    # Verify everything we intended to install is now present
    STILL_MISSING=""
    command -v rclone      >/dev/null 2>&1 || STILL_MISSING+=" $PKG_RCLONE"
    command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || STILL_MISSING+=" $PKG_FUSE"
    command -v ykman       >/dev/null 2>&1 || STILL_MISSING+=" $PKG_YK"

    if [ -n "$STILL_MISSING" ]; then
        error_box "Proton Drive Installer" \
"Failed to install:$STILL_MISSING

Check your package manager output and try again, or install
these packages manually, then re-run this installer."
    fi
    [ "$HAVE_TERM" = "yes" ] && echo "✓ Dependencies installed."
fi

# --- Verify rclone version ---------------------------------------------------------
RCLONE_VER=$(rclone version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
MAJOR=$(echo "$RCLONE_VER" | cut -d. -f1)
MINOR=$(echo "$RCLONE_VER" | cut -d. -f2)

if [ -z "$RCLONE_VER" ] || [ "$MAJOR" -lt 1 ] || { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -lt 64 ]; }; then
    ask_box "Proton Drive Installer" \
"Warning: rclone v${RCLONE_VER:-unknown} detected.
The Proton Drive backend requires rclone v1.64 or newer.

Continue anyway?" || error_box "Proton Drive Installer" "Aborted — please upgrade rclone."
else
    [ "$HAVE_TERM" = "yes" ] && echo "✓ rclone v$RCLONE_VER OK."
fi

# --- Create desktop launchers -------------------------------------------------------
if ask_box "Proton Drive Installer" \
"Dependencies are installed.

Create 'Proton Drive' launchers in your application menu?
(Mount launcher + Uninstall launcher)"; then

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LAUNCHER_SCRIPT="${SCRIPT_DIR}/proton-automount.sh"
    UNINSTALL_SCRIPT="${SCRIPT_DIR}/uninstall.sh"
    ICON_PATH="${SCRIPT_DIR}/proton.png"
    APPDIR="$HOME/.local/share/applications"

    [ -x "$LAUNCHER_SCRIPT" ] || chmod +x "$LAUNCHER_SCRIPT"
    [ -x "$UNINSTALL_SCRIPT" ] || chmod +x "$UNINSTALL_SCRIPT"
    mkdir -p "$APPDIR"

    cat > "$APPDIR/proton-drive.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Proton Drive
Comment=Mount your Proton Drive with YubiKey 2FA
Exec=${LAUNCHER_SCRIPT}
Icon=${ICON_PATH}
Terminal=false
Categories=Network;FileTools;
Actions=uninstall;

[Desktop Action uninstall]
Name=Uninstall Proton Drive
Icon=application-exit
Exec=${UNINSTALL_SCRIPT}
Terminal=false
EOF

    cat > "$APPDIR/proton-drive-uninstall.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Proton Drive Uninstall
Comment=Remove all proton-automount files and credentials
Exec=${UNINSTALL_SCRIPT}
Icon=${ICON_PATH}
Terminal=false
Categories=Network;FileTools;
EOF

# Refresh desktop databases so launchers appear WITHOUT logging out
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPDIR" 2>/dev/null || true
    fi
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 --noincremental 2>/dev/null || true
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then
        kbuildsycoca5 --noincremental 2>/dev/null || true
    fi

    # Some Plasma setups don't re-read the menu cache until the shell restarts.
    # Offer an immediate, non-destructive fix (panel flashes ~2s, no logout).
    if command -v kquitapp6 >/dev/null 2>&1; then
        if ask_box "Proton Drive Installer" \
"On KDE Plasma, new menu entries sometimes only appear after the
desktop shell restarts (your panel will flash for about two
seconds — no logout, no apps are closed).

Restart the desktop shell now so the launchers appear
immediately?"; then
            kquitapp6 plasmashell 2>/dev/null
            sleep 1
            nohup kstart plasmashell >/dev/null 2>&1 &
            SHELL_RESTARTED="yes"
        fi
    fi

    [ "$HAVE_TERM" = "yes" ] && echo "✓ Launchers created."
fi
# --- Done ----------------------------------------------------------------------------
msg_box "Proton Drive Installer" \
"Installation complete ✓

Mount your Proton Drive:
• Click 'Proton Drive' in your app menu
• Or run:  proton-automount.sh

First run will ask for your Proton username and
password, then your 2FA code each time."

[ "$HAVE_TERM" = "yes" ] && echo "=== Installation complete ==="
exit 0
