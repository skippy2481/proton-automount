#!/usr/bin/env bash
# Proton Drive auto-mount with interactive 2FA fallback

MOUNTPOINT="$HOME/ProtonDrive"
REMOTE="protondrive"     # your rclone remote name
LOGFILE="$HOME/.local/state/proton-mount.log"

log() { echo "$(date '+%F %T') $*" >> "$LOGFILE"; }

fetch_code() {
    # If a YubiKey is plugged in, grab the code directly
    if ykman info >/dev/null 2>&1; then
        ykman oath accounts code --single ProtonMail 2>/dev/null
    fi
}

ask_code() {
    local auto
    auto="$(fetch_code)"
    if [ -n "$auto" ]; then
        echo "$auto"
        return
    fi
    # No YubiKey (or it failed) — GUI prompt
    kdialog --title "Proton Drive" \
        --inputbox "Session expired. Enter your current 2FA code\n(from Yubico Authenticator / your phone):"
}

do_login() {
    local code
    code="$(ask_code)"
    [ -z "$code" ] && return 1
    # Store the fresh code in the remote (replaces stale one)
    rclone config update "$REMOTE" 2fa "$code"
    # Test the session before mounting
    timeout 25 rclone lsd "$REMOTE:" >/dev/null 2>&1
}

while true; do
    mkdir -p "$MOUNTPOINT"

    if mountpoint -q "$MOUNTPOINT"; then
        sleep 300; continue            # already mounted, nothing to do
    fi

    if timeout 20 rclone lsd "$REMOTE:" >/dev/null 2>&1; then
        # Session alive → mount silently
        rclone mount "$REMOTE:" "$MOUNTPOINT" \
            --vfs-cache-mode writes \
            --vfs-used-is-size \
            --daemon
        log "mounted"
    else
        # Session dead → ask for 2FA (do_login handles the popup)
        if do_login; then
            rclone mount "$REMOTE:" "$MOUNTPOINT" \
                --vfs-cache-mode writes \
                --vfs-used-is-size \
                --daemon
            notify-send "Proton Drive" "Mounted after login ✓"
        else
            # Popup blocked/empty/2FA wrong — try again later
            notify-send "Proton Drive" "Not mounted — will retry in 5 min" 2>/dev/null
        fi
    fi

    sleep 300
done
