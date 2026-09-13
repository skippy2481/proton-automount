#!/usr/bin/env bash
# Proton Drive auto-mount — click-to-mount with zero-persistence security
#
# Flow:
#   Fresh install: username/password wizard → saves credentials securely
#   Subsequent runs: YubiKey touch or TOTP popup → mounts
#   Unmount: from Dolphin or script → stays unmounted until next run
#
# Security: cached backend tokens are purged at three points
#   • At login start — forces fresh auth every time
#   • After mount confirmed — session runs from RAM only
#   • On scripted unmount — tokens die with the mount
#
# Requires: rclone >= 1.64, kdialog, FUSE/fuse3
# Logs: ~/.local/state/proton-mount.log

MOUNTPOINT="$HOME/ProtonDrive"
REMOTE="protondrive"
LOGFILE="$HOME/.local/state/proton-mount.log"
ENVFILE="$HOME/.config/proton-automount.env"
YK_TIMEOUT=30
RC_PREFIX="RCLONE_CONFIG_${REMOTE^^}_"

mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$ENVFILE")"

log() { echo "$(date '+%F %T') $*" >> "$LOGFILE"; }

# --- Dependency checks ---------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
    kdialog --title "Proton Drive" --error \
        "rclone is not installed.\n\nOn Fedora/Ultramarine:\nsudo dnf install rclone fuse3" 2>/dev/null
    exit 1
fi
if ! command -v kdialog >/dev/null 2>&1; then
    echo "ERROR: kdialog not found (KDE). Install it or swap kdialog" >&2
    echo "for your desktop's dialog tool in ask_code()." >&2
    exit 1
fi

# --- Unmount mode ---------------------------------------------------------
if [ "$1" = "unmount" ]; then
    if mountpoint -q "$MOUNTPOINT"; then
        fusermount3 -u "$MOUNTPOINT" || fusermount -u "$MOUNTPOINT"
        rclone config delete "$REMOTE" >/dev/null 2>&1
        log "Unmounted + purged backend credentials"
        notify-send "Proton Drive" "Unmounted ✓" 2>/dev/null
    else
        notify-send "Proton Drive" "Nothing mounted" 2>/dev/null
    fi
    exit 0
fi

# --- Already mounted? -----------------------------------------------------
if mountpoint -q "$MOUNTPOINT"; then
    notify-send "Proton Drive" "Already mounted at $MOUNTPOINT" 2>/dev/null
    exit 0
fi
mkdir -p "$MOUNTPOINT"

# --- Force a fresh login on every mount -----------------------------------
# Purge any cached backend credentials so login is always genuine
rclone config delete "$REMOTE" >/dev/null 2>&1
log "Purged cached backend credentials — fresh login required"

# --- First-run credential setup -------------------------------------------
setup_credentials() {
    local user pass
    user=$(kdialog --title "Proton Drive" \
        --inputbox "First-time setup — enter your Proton username (email):")
    [ -z "$user" ] && exit 1
    pass=$(kdialog --title "Proton Drive" \
        --password "Enter your Proton password:")
    [ -z "$pass" ] && exit 1

    umask 077
    printf 'PROTON_USERNAME=%q\nPROTON_PASSWORD=%q\n' "$user" "$pass" > "$ENVFILE"
    unset user pass
    log "Credentials saved to $ENVFILE (mode 600)"
}

if [ ! -r "$ENVFILE" ]; then
    log "No credentials found — starting first-time setup"
    setup_credentials
fi
# shellcheck source=/dev/null
source "$ENVFILE"

if [ -z "${PROTON_USERNAME:-}" ] || [ -z "${PROTON_PASSWORD:-}" ]; then
    kdialog --title "Proton Drive" --error \
        "$ENVFILE exists but is missing credentials.\nDelete it to redo setup:\nrm $ENVFILE" 2>/dev/null
    exit 1
fi

# --- rclone wrapper --------------------------------------------------------
# $1 = 2FA code ("" = account has no 2FA); remaining args = rclone args
rclone_run() {
    local code="$1"; shift
    if [ -n "$code" ]; then
        env \
            "${RC_PREFIX}TYPE=protondrive" \
            "${RC_PREFIX}USERNAME=${PROTON_USERNAME}" \
            "${RC_PREFIX}PASSWORD=$(rclone obscure -- "$PROTON_PASSWORD")" \
            "${RC_PREFIX}2FA=${code}" \
            rclone "$@"
    else
        env \
            "${RC_PREFIX}TYPE=protondrive" \
            "${RC_PREFIX}USERNAME=${PROTON_USERNAME}" \
            "${RC_PREFIX}PASSWORD=$(rclone obscure -- "$PROTON_PASSWORD")" \
            rclone "$@"
    fi
}

fetch_code() {
    if ykman info >/dev/null 2>&1; then
        local code
        code=$(timeout "$YK_TIMEOUT" \
##################--- run ykman oath account list get proton name for totp codes
##################--- and put them in the Place Holder in the next line down between the ("")
	    ykman oath accounts code --single "<protonmail yubikey entry>" 2>/dev/null)
        [ -z "$code" ] && \
            log "WARN: YubiKey present but no code returned — credential name may be wrong, or touch timed out"
        echo "$code"
    fi
}

ask_code() {
    local auto pid

    if ykman info >/dev/null 2>&1; then
        kdialog --title "Proton Drive" --msgbox "Touch your YubiKey to sign in..." &
        pid=$!
        auto=$(fetch_code)
        kill "$pid" 2>/dev/null

        if [ -n "$auto" ]; then
            log "2FA code received from YubiKey"
            kdialog --title "Proton Drive" \
                --inputbox "Code received from YubiKey — submitting automatically:" "$auto" &
            pid=$!
            sleep 2
            kill "$pid" 2>/dev/null
            echo "$auto"
            return
        fi
        log "Falling back to manual 2FA popup"
    fi

    # Leave empty if your account has NO 2FA enabled
    kdialog --title "Proton Drive" \
        --inputbox "Enter your current 2FA code\n(from Yubico Authenticator / your phone):\n\nLeave empty if 2FA is disabled on your account."
}

# --- Main: get code, mount -------------------------------------------------
code="$(ask_code)"
[ -z "$code" ] && log "No 2FA code — attempting password-only login"

# --daemon-wait ensures rclone waits for actual mount before exiting
rclone_run "$code" mount "$REMOTE:" "$MOUNTPOINT" \
    --vfs-cache-mode writes \
    --vfs-used-is-size \
    --daemon \
    --daemon-wait 2m \
    --log-file "$LOGFILE" \
    --log-level INFO

# Grace period for slow connections (up to 150 seconds total with daemon-wait)
for i in $(seq 1 30); do
    sleep 5
    mountpoint -q "$MOUNTPOINT" && break
done

# Secondary check: if mountpoint still not ready but rclone daemon is alive,
# give it more time (covers very slow networks without false failures)
if ! mountpoint -q "$MOUNTPOINT"; then
    if pgrep -f "rclone.*mount.*$MOUNTPOINT" >/dev/null 2>&1; then
        log "Daemon still active — extending wait"
        for i in $(seq 1 18); do
            sleep 5
            mountpoint -q "$MOUNTPOINT" && break
        done
    fi
fi

if mountpoint -q "$MOUNTPOINT"; then
    log "Mounted"
    notify-send "Proton Drive" "Mounted ✓" 2>/dev/null
    # Daemon's session lives in memory — purge tokens so they only exist during login
    rclone config delete "$REMOTE" >/dev/null 2>&1
    log "Purged backend tokens from rclone.conf — session continues in memory"
else
    log "WARN: login or mount failed — see rclone log lines above"
    notify-send "Proton Drive" "Mount failed — see $LOGFILE" 2>/dev/null
    kdialog --title "Proton Drive" --error \
        "Mount failed.\n\nCheck the log for details:\n$LOGFILE" 2>/dev/null
    exit 1
fi
