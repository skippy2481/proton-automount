#!/usr/bin/env bash
# Proton Drive auto-mount — click-to-mount with zero-persistence security
# See Line 30 for Manual Yubikey TOTP Name Entry
# Flow:
#   Fresh install: username/password wizard → saves credentials securely
#   Subsequent runs: YubiKey touch or TOTP popup → mounts
#   Unmount: from Dolphin/file manager or script → stays unmounted until next run
#
# Security: cached backend tokens are purged at three points
#   • At login start — forces fresh auth every time
#   • After mount confirmed — session runs from RAM only
#   • On scripted unmount — tokens die with the mount
#
# Requires: rclone >= 1.64, kdialog (KDE) or zenity (GNOME/other), FUSE/fuse3
# Logs: ~/.local/state/proton-mount.log
#
# --- YubiKey credential (optional, usually AUTO-DETECTED) ---------------------
# The script automatically finds a YubiKey credential whose name contains
# your Proton username — most setups need NO editing here.
#
#
MOUNTPOINT="$HOME/ProtonDrive"
REMOTE="protondrive"
LOGFILE="$HOME/.local/state/proton-mount.log"
ENVFILE="$HOME/.config/proton-automount.env"
YK_TIMEOUT=30
# If auto discovery fails run ykman oath accounts list get proton account
# It is usually (Proton Mail:user@protonmail.com)
# Yubikey Name for proton totp code between ("") on the nex line down
YK_CRED=""
RC_PREFIX="RCLONE_CONFIG_${REMOTE^^}_"

mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$ENVFILE")"

log() { echo "$(date '+%F %T') $*" >> "$LOGFILE"; }

# --- Detect dialog tool ----------------------------------------------------
# kdialog (KDE) → zenity (GNOME/most distros) → plain terminal prompts
if command -v kdialog >/dev/null 2>&1; then
    DLG="kdialog"
elif command -v zenity >/dev/null 2>&1; then
    DLG="zenity"
elif [ -t 0 ]; then
    DLG="term"
else
    echo "ERROR: no dialog tool found (kdialog or zenity) and no terminal." >&2
    echo "KDE Plasma:  sudo dnf install kdialog" >&2
    echo "GNOME/other: sudo dnf install zenity   (or apt/pacman equivalent)" >&2
    exit 1
fi

# --- Dialog helpers (dispatch to whatever is available) ---------------------
# ask_input: $1=title $2=text [$3=prefill] → stdout (empty + nonzero on cancel)
ask_input() {
    case "$DLG" in
        kdialog) kdialog --title "$1" --inputbox "$2" "${3:-}" ;;
        zenity)  zenity --entry --title "$1" --text "$2" --entry-text "${3:-}" 2>/dev/null ;;
        term)    local a; read -rp "$2 " a; echo "$a" ;;
    esac
}

ask_password() {  # $1=title $2=text → stdout
    case "$DLG" in
        kdialog) kdialog --title "$1" --password "$2" ;;
        zenity)  zenity --password --title "$1" --text "$2" 2>/dev/null ;;
        term)    local a; read -rsp "$2 " a; echo >&2; echo "$a" ;;
    esac
}

msg_info() {  # $1=title $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --msgbox "$2" ;;
        zenity)  zenity --info --title "$1" --text "$2" >/dev/null 2>&1 ;;
        term)    echo "── $1 ──"; echo "$2" ;;
    esac
}

msg_error() {  # $1=title $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --error "$2" ;;
        zenity)  zenity --error --title "$1" --text "$2" >/dev/null 2>&1 ;;
        term)    echo "ERROR: $2" >&2 ;;
    esac
}

# --- Dependency checks -------------------------------------------------------
if ! command -v rclone >/dev/null 2>&1; then
    msg_error "Proton Drive" \
"rclone is not installed.

On Fedora/Ultramarine:
sudo dnf install rclone fuse3"
    exit 1
fi

# --- Unmount mode -----------------------------------------------------------
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

# --- Already mounted? --------------------------------------------------------
if mountpoint -q "$MOUNTPOINT"; then
    notify-send "Proton Drive" "Already mounted at $MOUNTPOINT" 2>/dev/null
    exit 0
fi
mkdir -p "$MOUNTPOINT"

# --- Force a fresh login on every mount ---------------------------------------
# Purge any cached backend credentials so login is always genuine
rclone config delete "$REMOTE" >/dev/null 2>&1
log "Purged cached backend credentials — fresh login required"

# --- First-run credential setup -----------------------------------------------
setup_credentials() {
    local user pass
    user=$(ask_input "Proton Drive" "First-time setup — enter your Proton username (email):")
    [ -z "$user" ] && exit 1
    pass=$(ask_password "Proton Drive" "Enter your Proton password:")
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
    msg_error "Proton Drive" \
"$ENVFILE exists but is missing credentials.
Delete it to redo setup:
rm $ENVFILE"
    exit 1
fi

# --- rclone wrapper -------------------------------------------------------------
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
    ykman info >/dev/null 2>&1 || return

    local cred code

    if [ -n "$YK_CRED" ]; then
        cred="$YK_CRED"                     # manual override always wins
    else
        # Auto-detect: prefer a Proton Mail credential matching the username,
        # fall back to any credential containing it, and if MORE than one
        # candidate matches, refuse to guess — tell the user to set YK_CRED.
        local list
        list=$(ykman oath accounts list 2>/dev/null)

        cred=$(grep -F "Proton Mail:$PROTON_USERNAME" <<<"$list" | head -n1 \
            | sed 's/[[:space:]]*$//')

        if [ -z "$cred" ]; then
            local matches count
            matches=$(grep -F "$PROTON_USERNAME" <<<"$list" | sed 's/[[:space:]]*$//')
            count=$(wc -l <<<"$matches")
            if [ "$count" -gt 1 ]; then
                log "Multiple YubiKey credentials match '$PROTON_USERNAME':"
                while IFS= read -r m; do log "  candidate: $m"; done <<<"$matches"
                log "Auto-detect disabled — set YK_CRED at the top of the script"
                cred=""
            else
                cred="$matches"
            fi
        fi
        [ -n "$cred" ] && log "YubiKey credential auto-detected: $cred"
    fi
    [ -z "$cred" ] && { log "No matching YubiKey credential found"; return; }

    code=$(timeout "$YK_TIMEOUT" \
        ykman oath accounts code --single "$cred" 2>/dev/null)

    [ -z "$code" ] && \
        log "WARN: YubiKey present but no code returned — credential may be wrong, or touch timed out"
    echo "$code"
}
ask_code() {
    local auto pid

    if ykman info >/dev/null 2>&1; then
        # NOTE: launch the dialog binary DIRECTLY (not via msg_info) so that
        # $! is the dialog process itself — killing $pid then actually
        # dismisses the popup. Function-backgrounding creates a subshell
        # whose child (the dialog) survives the kill.
        case "$DLG" in
            kdialog) kdialog --title "Proton Drive" --msgbox "Touch your YubiKey to sign in..." & ;;
            zenity)  zenity --info --title "Proton Drive" --text "Touch your YubiKey to sign in..." >/dev/null 2>&1 & ;;
            *)       echo "Touch your YubiKey to sign in..." ;;
        esac
        pid=$!
        auto=$(fetch_code)
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null

        if [ -n "$auto" ]; then
            log "2FA code received from YubiKey"
            # Brief display of the code being submitted (auto-closes)
            case "$DLG" in
                kdialog) kdialog --title "Proton Drive" --inputbox \
                    "Code received from YubiKey — submitting automatically:" "$auto" & ;;
                zenity)  zenity --entry --title "Proton Drive" \
                    --text "Code received from YubiKey — submitting automatically:" \
                    --entry-text "$auto" >/dev/null 2>&1 & ;;
                *)       echo "Code: $auto" ;;
            esac
            pid=$!
            sleep 2
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            echo "$auto"
            return
        fi
        log "Falling back to manual 2FA popup"
    fi

    # Leave empty if your account has NO 2FA enabled
    ask_input "Proton Drive" \
"Enter your current 2FA code
(from Yubico Authenticator / your phone):

Leave empty if 2FA is disabled on your account."
}
# --- Main: get code, mount ---------------------------------------------------------
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
    msg_error "Proton Drive" \
"Mount failed.

Check the log for details:
$LOGFILE"
    exit 1
fi
