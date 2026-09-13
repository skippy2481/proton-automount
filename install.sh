#!/usr/bin/env bash
# Installer for proton-automount
# Installs dependencies: rclone, FUSE, ykman (YubiKey support),
# libnotify (desktop notifications).
#
# NOTE: kdialog is NOT installed here — it ships with KDE Plasma,
# which this project targets. If kdialog is missing, you're probably
# not on Plasma; see the README for requirements.

MISSING=()

# --- Detect package manager ------------------------------------------------
PKG=""
if   command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
elif command -v zypper  >/dev/null 2>&1; then PKG=zypper
else
    echo "ERROR: No supported package manager found (dnf/apt/pacman/zypper)." >&2
    echo "Install manually: rclone fuse3 yubikey-manager libnotify" >&2
    exit 1
fi
echo "Detected package manager: $PKG"

# --- Check for kdialog (KDE Plasma) — required, but not installed here -----
if ! command -v kdialog >/dev/null 2>&1; then
    echo "WARNING: kdialog not found. This project targets KDE Plasma,"
    echo "where kdialog is preinstalled. Install it manually if needed."
fi

# --- Check what's missing ---------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || MISSING+=("$2"); }

need rclone      rclone
need ykman       yubikey-manager
need notify-send libnotify

# FUSE: check both the mount helper and the library
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 \
    || MISSING+=(fuse3)

# --- Install what's missing ---------------------------------------------------
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Installing: ${MISSING[*]}"
    case "$PKG" in
        dnf)    sudo dnf install -y "${MISSING[@]}" ;;
        apt)    sudo apt-get update && sudo apt-get install -y "${MISSING[@]}" ;;
        pacman) sudo pacman -Sy --needed "${MISSING[@]}" ;;
        zypper) sudo zypper install -y "${MISSING[@]}" ;;
    esac
else
    echo "All dependencies already installed."
fi

# --- Verify rclone version (protondrive backend needs >= 1.64) ---------------
if command -v rclone >/dev/null 2>&1; then
    version=$(rclone version 2>/dev/null | head -1 | awk '{print $2}')
    echo "rclone version: $version"
    major=$(echo "$version" | sed 's/v//' | cut -d. -f1)
    minor=$(echo "$version" | sed 's/v//' | cut -d. -f2)
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 64 ]; }; then
        echo
        echo "⚠ WARNING: rclone $version is older than v1.64.0 — the Proton Drive"
        echo "backend was added in v1.64.0. The mount script will likely fail."
        echo "Upgrade rclone (e.g. 'sudo rclone selfupdate' or your distro's method)."
    fi
else
    echo "ERROR: rclone still not found after install — check the output above." >&2
    exit 1
fi

echo
echo "Setup complete. Next steps:"
echo "  1. Edit the YubiKey credential name in proton-automount.sh (see the"
echo "     '####' comment), or skip if you don't use a YubiKey"
echo "  2. Run: ./proton-automount.sh"
echo "     (first run asks for your Proton username and password)"
