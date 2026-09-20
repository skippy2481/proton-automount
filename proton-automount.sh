#!/usr/bin/env bash
# Proton Drive auto-mount — click-to-mount with zero-persistence security
# v1.3.1 — secret-store credentials (KWallet / GNOME Keyring), reinstall reuse
#
# Flow:
#   Fresh install: username/password wizard → saves credentials securely
#   Reinstall (saved password kept): username only → reuse offer
#   Subsequent runs: YubiKey touch or TOTP popup → mounts
#   Unmount: from file manager or script → stays unmounted until next run
#
# Security: cached backend tokens are purged at three points
#   • At login start — forces fresh auth every time
#   • After mount confirmed — session runs from RAM only
#   • On scripted unmount — tokens die with the mount
#
# Credential storage (v1.3.1): CRED_STORE in the env file selects
#   kwallet | gnome_keyring | env. Username lives in the 600-perm env
#   file (it is the lookup key, not the secret); the PASSWORD lives in
#   the OS secret store under the [AUTO] namespace when a store is used:
#     entry:  [AUTO]<username>:password
#   The [AUTO] prefix + private folder/group means this script can
#   never read, overwrite, or delete a human's own keyring entries.
#
# v1.3.1 FIX: when no recorded CRED_STORE exists (fresh install,
# env file deleted), prefer an available OS secret store over plaintext
# env file — no more silent fallback to disk-stored passwords.
#
# Requires: rclone >= 1.64, kdialog (KDE) or zenity (GNOME/other), FUSE/fuse3
# Logs: ~/.local/state/proton-mount.log
#
# --- YubiKey credential (optional, usually AUTO-DETECTED) ---------------------
# The script automatically finds a YubiKey credential whose name contains
# your Proton username — most setups need NO editing here.
# If auto discovery fails run: ykman oath accounts list
# It is usually (Proton Mail:user@protonmail.com)
MOUNTPOINT="$HOME/ProtonDrive"
REMOTE="protondrive"
LOGFILE="$HOME/.local/state/proton-mount.log"
ENVFILE="$HOME/.config/proton-automount.env"
YK_TIMEOUT=30
YK_CRED=""
RC_PREFIX="RCLONE_CONFIG_${REMOTE^^}_"

# --- Secret store namespace (collision-safe — see header) --------------------
SECRET_WALLET="kdewallet"          # KWallet wallet name (KDE default)
SECRET_FOLDER="ProtonRcloneAuto"   # KWallet folder
SECRET_GROUP="proton-rclone-auto"  # GNOME Keyring attribute group

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
# ask_input: $1=title $2=text [$3=prefill] [$4=ok-label] [$5=cancel-label]
ask_input() {
    case "$DLG" in
        kdialog) kdialog --title "$1" --inputbox "$2" "${3:-}" ;;
        zenity)
            local args=(--entry --title "$1" --text "$2" --entry-text "${3:-}")
            [ -n "${4:-}" ] && args+=(--ok-label "$4")
            [ -n "${5:-}" ] && args+=(--cancel-label "$5")
            zenity "${args[@]}" 2>/dev/null
            ;;
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
        zenity)  zenity --info --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    echo "── $1 ──"; echo "$2" ;;
    esac
}

msg_error() {  # $1=title $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --error "$2" ;;
        zenity)  zenity --error --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    echo "ERROR: $2" >&2 ;;
    esac
}

ask_yesno() {  # $1=title $2=text (returns 0 = yes, 1 = no)
    case "$DLG" in
        kdialog) kdialog --title "$1" --yesno "$2" ;;
        zenity)  zenity --question --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    local a; read -rp "$2 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ] ;;
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

# --- Unmount mode ------------------------------------------------------------
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

# =============================================================================
# SECRET STORE (v1.3.1 — read/write/delete password by username)
# Backends: kwallet (kwallet-query), gnome_keyring (secret-tool), env fallback.
# All keyring access uses the [AUTO] namespace EXCLUSIVELY — a human's own
# Proton entries in the same keyring can never be read or clobbered here.
# =============================================================================

# read password for $1 (username) → stdout, empty if absent/unavailable
# CRITICAL: only emit output when the backend exits 0 — kwallet-query
# prints its error text to stdout with a non-zero exit (e.g. entry not
# found, exit 4), and naively capturing that treated "entry not found"
# as a stored password. Exit status is the truth; output alone is not.
secret_read_password() {
    local val=""
    case "$SECRET_BACKEND" in
        kwallet)
            [ -n "$1" ] || return
            if val=$(kwallet-query -r "[AUTO]$1:password" \
                        -f "$SECRET_FOLDER" "$SECRET_WALLET" 2>/dev/null); then
                [ -n "$val" ] && printf '%s' "$val"
            fi
            ;;
        gnome_keyring)
            [ -n "$1" ] || return
            if val=$(secret-tool lookup "$SECRET_GROUP" "[AUTO]$1:password" \
                        "type" "AUTO" 2>/dev/null); then
                [ -n "$val" ] && printf '%s' "$val"
            fi
            ;;
        *) : ;;
    esac
}

# ==========================================================================
# WARNING: REMOVE_THIS_KEY — SENSITIVE WRITE TO PERSISTENT SECRET STORE
# This function writes the Proton PASSWORD into the OS keyring.
# - Entry names MUST match secret_read_password exactly or secrets orphan
# - The [AUTO] prefix is mandatory — it is the collision guard
# ==========================================================================
secret_write_password() {  # $1=username  $2=password
    case "$SECRET_BACKEND" in
        kwallet)
            printf '%s' "$2" | kwallet-query -w "[AUTO]$1:password" \
                                             -f "$SECRET_FOLDER" "$SECRET_WALLET" >/dev/null 2>&1
            ;;
        gnome_keyring)
            printf '%s' "$2" | secret-tool store "$SECRET_GROUP" "[AUTO]$1:password" \
                                "type" "AUTO" --label "Proton Automount" >/dev/null 2>&1
            ;;
    esac
}

secret_delete_password() {  # $1=username (uninstall flow, guarded by DELETE PASS)
    case "$SECRET_BACKEND" in
        kwallet)
            kwallet-query -D "[AUTO]$1:password" -f "$SECRET_FOLDER" "$SECRET_WALLET" 2>/dev/null || true
            ;;
        gnome_keyring)
            secret-tool clear "$SECRET_GROUP" "[AUTO]$1:password" "type" "AUTO" 2>/dev/null || true
            ;;
    esac
}

# --- First-run credential setup -----------------------------------------------
# Order matters: username FIRST (it is the lookup key), THEN probe the keyring
# for a saved password, THEN offer reuse or a fresh password.
setup_credentials() {
    local user pass existing

    user=$(ask_input "Proton Drive" \
        "First-time setup — enter your Proton username (email):" "${PROTON_USERNAME:-}")
    [ -z "$user" ] && exit 1

    # Probe for a saved password from a previous install (uninstall kept it)
    if [ "$SECRET_BACKEND" = "kwallet" ] || [ "$SECRET_BACKEND" = "gnome_keyring" ]; then
        existing=$(secret_read_password "$user")
        if [ -n "$existing" ]; then
            if ask_yesno "Proton Drive" \
"A saved password for $user was found in $SECRET_BACKEND
(left over from a previous install).

Use the saved password?

Yes — reuse it (no new entry needed)
No  — enter a new password (overwrites the saved one)"; then
                umask 077
                printf 'PROTON_USERNAME=%q\nCRED_STORE=%q\n' "$user" "$SECRET_BACKEND" > "$ENVFILE"
                log "Reusing stored password for $user from $SECRET_BACKEND (reinstall)"
                PROTON_USERNAME="$user"
                PROTON_PASSWORD="$existing"
                unset existing user pass
                return
            fi
            # declined → fall through to overwrite path
        fi
        unset existing
    fi

    pass=$(ask_password "Proton Drive" "Enter your Proton password:")
    [ -z "$pass" ] && exit 1

    umask 077
    if [ "$SECRET_BACKEND" = "kwallet" ] || [ "$SECRET_BACKEND" = "gnome_keyring" ]; then
        secret_write_password "$user" "$pass"
        # verify the write actually landed — refuse to claim success blindly
        local check
        check=$(secret_read_password "$user")
        if [ "$check" != "$pass" ]; then
            log "ERROR: credential write to $SECRET_BACKEND failed verification"
            msg_error "Proton Drive" \
"Saving the password to $SECRET_BACKEND failed.

The mount will still be attempted this once. Please re-run
setup (or check that your wallet/keyring is unlocked)."
        else
            log "Password stored in $SECRET_BACKEND under [AUTO]$user:password"
        fi
        unset check
        printf 'PROTON_USERNAME=%q\nCRED_STORE=%q\n' "$user" "$SECRET_BACKEND" > "$ENVFILE"
        log "Username + storage choice saved to $ENVFILE (no password on disk)"
        PROTON_USERNAME="$user"; PROTON_PASSWORD="$pass"
    else
        printf 'PROTON_USERNAME=%q\nPROTON_PASSWORD=%q\nCRED_STORE=%q\n' \
            "$user" "$pass" "env" > "$ENVFILE"
        log "Credentials saved to $ENVFILE (mode 600)"
        PROTON_USERNAME="$user"; PROTON_PASSWORD="$pass"
    fi
    unset user pass
}

# --- Load configuration + credential dispatch (v1.3.1 FIX) ---------------------
# Env file provides: PROTON_USERNAME (always, when set up) and, in legacy
# env mode, PROTON_PASSWORD. CRED_STORE selects where the password lives.
if [ -r "$ENVFILE" ]; then
    # shellcheck source=/dev/null
    source "$ENVFILE"
fi

# v1.3.1 FIX: when no recorded choice exists (fresh install, or env file deleted),
# never silently default to plaintext-on-disk — prefer an available OS
# secret store, matched to the desktop environment. An explicit CRED_STORE
# written by the installer always wins over this heuristic.
if [ -z "${CRED_STORE:-}" ]; then
    case "$XDG_CURRENT_DESKTOP" in
        *KDE*)
            if command -v kwallet-query >/dev/null 2>&1; then
                CRED_STORE="kwallet"
            elif command -v secret-tool >/dev/null 2>&1; then
                CRED_STORE="gnome_keyring"
            fi
            ;;
        *)
            if command -v secret-tool >/dev/null 2>&1; then
                CRED_STORE="gnome_keyring"
            elif command -v kwallet-query >/dev/null 2>&1; then
                CRED_STORE="kwallet"
            fi
            ;;
    esac
    [ -z "${CRED_STORE:-}" ] && CRED_STORE="env"
fi
SECRET_BACKEND="${CRED_STORE}"

# Try to load password from selected backend
if [ "$SECRET_BACKEND" = "kwallet" ] || [ "$SECRET_BACKEND" = "gnome_keyring" ]; then
    [ -n "${PROTON_USERNAME:-}" ] && PROTON_PASSWORD=$(secret_read_password "$PROTON_USERNAME")
fi
[ -z "${PROTON_PASSWORD:-}" ] && PROTON_PASSWORD=""

# Missing something? Run wizard
if [ -z "${PROTON_USERNAME:-}" ] || [ -z "${PROTON_PASSWORD:-}" ]; then
    log "Missing credentials — starting setup wizard"
    setup_credentials
fi

# Final validation (should never reach here with missing creds)
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
        # fall back to any credential containing it; if MORE than one
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
        # Launch the dialog binary DIRECTLY (not via msg_info) so that
        # $! is the dialog process itself — killing $pid actually
        # dismisses the popup.
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

# --- Main: get code, mount ----------------------------------------------------
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
    # v1.3.1: if the password lives in a secret store, offer to update it
    # (covers password-changed-on-Proton). No in-place retry: TOTP codes
    # are single-use — a fresh run fetches a fresh code.
    if [ "$SECRET_BACKEND" = "kwallet" ] || [ "$SECRET_BACKEND" = "gnome_keyring" ]; then
        if ask_yesno "Proton Drive" \
"Mount failed.

If your Proton password has changed since it was saved,
update the stored password now?"; then
            local_newpass=$(ask_password "Proton Drive" "Enter new Proton password for $PROTON_USERNAME:")
            if [ -n "$local_newpass" ]; then
                secret_write_password "$PROTON_USERNAME" "$local_newpass"
                log "Stored password updated in $SECRET_BACKEND"
                msg_info "Proton Drive" \
"Password updated.

Run Proton Drive again to mount with the new password."
                notify-send "Proton Drive" "Password updated — run again" 2>/dev/null
                unset local_newpass
                exit 1
            fi
        fi
    fi
    notify-send "Proton Drive" "Mount failed — see $LOGFILE" 2>/dev/null
    msg_error "Proton Drive" \
"Mount failed.

Check the log for details:
$LOGFILE"
    exit 1
fi
