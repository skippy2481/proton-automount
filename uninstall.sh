#!/usr/bin/env bash
# Uninstaller for proton-automount
# Removes: saved credentials (env file + optional keyring entry), rclone
# backend tokens, VFS caches, mountpoint, the log, and app menu launchers.
# Does NOT touch anything else in rclone.conf.
#
# Refuses to run while ~/ProtonDrive is mounted. Unmount first, then
# run the uninstaller again.
#
# The stored keyring password is only removed with a TYPED confirmation
# ("DELETE PASS") — misclicks can never destroy it. Keeping the password
# enables the reinstall-reuse flow (wizard offers to reuse it).

ENVFILE="$HOME/.config/proton-automount.env"
MOUNTPOINT="$HOME/ProtonDrive"
APPDIR="$HOME/.local/share/applications"

# --- Secret store namespace (must match proton-automount.sh) -----------------
SECRET_WALLET="kdewallet"
SECRET_FOLDER="ProtonRcloneAuto"
SECRET_GROUP="proton-rclone-auto"

# --- Snapshot credentials config BEFORE anything is deleted -------------------
# We need to know the backend + username to offer keyring cleanup later;
# capturing them now avoids the "deleted the env file then tried to read it"
# ordering bug.
CREDS_BACKEND="env"
CREDS_USERNAME=""
if [ -r "$ENVFILE" ]; then
    # shellcheck source=/dev/null
    source "$ENVFILE" 2>/dev/null
    CREDS_BACKEND="${CRED_STORE:-env}"
    CREDS_USERNAME="${PROTON_USERNAME:-}"
fi

# --- Dialog dispatch (kdialog → zenity → terminal) ---------------------------
if command -v kdialog >/dev/null 2>&1; then
    DLG="kdialog"
elif command -v zenity >/dev/null 2>&1; then
    DLG="zenity"
elif [ -t 0 ]; then
    DLG="term"
else
    echo "ERROR: no dialog tool found (kdialog or zenity) and no terminal." >&2
    exit 1
fi

msg_info() {  # $1=title  $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --msgbox "$2" ;;
        zenity)  zenity --info --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    echo "── $1 ──"; echo "$2" ;;
    esac
}

msg_error() {  # $1=title  $2=text
    case "$DLG" in
        kdialog) kdialog --title "$1" --error "$2" ;;
        zenity)  zenity --error --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    echo "ERROR: $1 — $2" >&2 ;;
    esac
}

ask_yesno() {  # $1=title  $2=text  (0 = yes, 1 = no)
    case "$DLG" in
        kdialog) kdialog --title "$1" --yesno "$2" ;;
        zenity)  zenity --question --title="$1" --text="$2" >/dev/null 2>&1 ;;
        term)    local a; read -rp "$2 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ] ;;
    esac
}

# $1=title $2=text [$3=prefill] [$4=ok-label] [$5=cancel-label]
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

# --- Blocked while mounted -------------------------------------------------
if mountpoint -q "$MOUNTPOINT"; then
    notify-send -u critical "Proton Drive Uninstall" \
        "Blocked — drive is mounted!" 2>/dev/null
    msg_error "Proton Drive Uninstall" \
"Cannot uninstall while Proton Drive is mounted!

Please unmount it first:
• In your file manager: right-click ~/ProtonDrive → Unmount
• Or in a terminal: proton-automount.sh unmount

Then run this uninstaller again."
    exit 1
fi

# --- Lingering daemon check ---------------------------------------------------
DAEMON_PIDS=$(pgrep -f "rclone.*mount.*$MOUNTPOINT" 2>/dev/null)
if [ -n "$DAEMON_PIDS" ]; then
    if ask_yesno "Proton Drive Uninstall" \
"A leftover rclone process for this mount was found (no longer
mounted, but still running):

$DAEMON_PIDS

Terminate it before removing files? (recommended)"; then
        # Graceful shutdown first, then force
        kill $DAEMON_PIDS 2>/dev/null
        for i in $(seq 1 10); do
            sleep 1
            pgrep -f "rclone.*mount.*$MOUNTPOINT" >/dev/null 2>&1 || break
        done
        pkill -9 -f "rclone.*mount.*$MOUNTPOINT" 2>/dev/null
        DAEMON_KILLED="yes"
    else
        DAEMON_KILLED="skipped"
    fi
fi

# --- Confirmation -----------------------------------------------------------
CONFIRM_TEXT="This will remove ALL proton-automount data:

• Saved credentials ($ENVFILE)"
if [ "$CREDS_BACKEND" = "kwallet" ] || [ "$CREDS_BACKEND" = "gnome_keyring" ]; then
    CONFIRM_TEXT="$CONFIRM_TEXT
• Stored password in $CREDS_BACKEND (typed confirmation required)"
fi
CONFIRM_TEXT="$CONFIRM_TEXT
• rclone backend tokens ([protondrive] in rclone.conf)
• VFS file caches (~/.cache/rclone/vfs*/protondrive*)
• Mountpoint directory ($MOUNTPOINT)
• Log (~/.local/state/proton-mount.log)
• App menu launchers (proton-drive*.desktop)

Remove everything now?"

ask_yesno "Proton Drive Uninstall" "$CONFIRM_TEXT" || exit 0

# --- Removal ------------------------------------------------------------------
results=""

# --- Secret-store cleanup (typed confirmation, BEFORE env file deletion) -------
# Values snapshotted at the top — safe to prompt even though the env file
# is removed just below. Detection trusts backend EXIT STATUS only:
# kwallet-query prints its error text to stdout on failure (e.g. exit 4
# for entry-not-found), which previously faked "credentials found".
if [ "$CREDS_BACKEND" = "kwallet" ] || [ "$CREDS_BACKEND" = "gnome_keyring" ]; then
    HAS_CREDS="no"
    val=""
    if [ -n "$CREDS_USERNAME" ]; then
        case "$CREDS_BACKEND" in
            kwallet)
                if val=$(kwallet-query -r "[AUTO]$CREDS_USERNAME:password" \
                            -f "$SECRET_FOLDER" "$SECRET_WALLET" 2>/dev/null); then
                    [ -n "$val" ] && HAS_CREDS="yes"
                fi
                ;;
            gnome_keyring)
                if val=$(secret-tool lookup "$SECRET_GROUP" "[AUTO]$CREDS_USERNAME:password" \
                            "type" "AUTO" 2>/dev/null); then
                    [ -n "$val" ] && HAS_CREDS="yes"
                fi
                ;;
        esac
        unset val
    fi

    if [ "$HAS_CREDS" = "yes" ]; then
        typed=$(ask_input "Proton Drive Uninstall" \
"WARNING — PERMANENT DELETION

This will delete the password stored in $CREDS_BACKEND for:
  [AUTO]$CREDS_USERNAME:password

Proton uses zero-access encryption: if you lose this password,
your files and email CANNOT be recovered — not even Proton
Support can decrypt them.

Make sure you have the password recorded elsewhere (password
manager, recovery sheet) before continuing.

To confirm, type exactly:  DELETE PASS" \
            "" "DELETE" "KEEP")
        if [ "$typed" = "DELETE PASS" ]; then
            # ==========================================================================
            # WARNING: REMOVE_THIS_KEY — DELETES PERSISTENT CREDENTIALS
            # Guarded by typed confirmation; [AUTO] prefix limits blast radius.
            # ==========================================================================
            case "$CREDS_BACKEND" in
                kwallet)
                    kwallet-query -D "[AUTO]$CREDS_USERNAME:password" \
                                  -f "$SECRET_FOLDER" "$SECRET_WALLET" 2>/dev/null || true
                    ;;
                gnome_keyring)
                    secret-tool clear "$SECRET_GROUP" "[AUTO]$CREDS_USERNAME:password" \
                                      "type" "AUTO" 2>/dev/null || true
                    ;;
            esac
            # verify the deletion actually happened (exit-status safe)
            val=""
            case "$CREDS_BACKEND" in
                kwallet)
                    if val=$(kwallet-query -r "[AUTO]$CREDS_USERNAME:password" \
                                -f "$SECRET_FOLDER" "$SECRET_WALLET" 2>/dev/null); then
                        HAS_CREDS="still"
                    else
                        HAS_CREDS="gone"
                    fi
                    ;;
                gnome_keyring)
                    if val=$(secret-tool lookup "$SECRET_GROUP" "[AUTO]$CREDS_USERNAME:password" \
                                "type" "AUTO" 2>/dev/null) && [ -n "$val" ]; then
                        HAS_CREDS="still"
                    else
                        HAS_CREDS="gone"
                    fi
                    ;;
            esac
            unset val
            if [ "$HAS_CREDS" = "gone" ]; then
                results+="✓ Removed stored password from $CREDS_BACKEND\n"
            else
                results+="⚠ Stored password may still exist in $CREDS_BACKEND — check manually\n"
            fi
        else
            results+="ℹ Credential deletion CANCELLED — password kept in $CREDS_BACKEND\n"
        fi
    else
        results+="• No stored password found in $CREDS_BACKEND\n"
    fi
fi

if rm -f "$ENVFILE" 2>/dev/null; then results+="✓ Removed credentials file\n"
else results+="• No credentials file found\n"; fi

if [ "${DAEMON_KILLED:-}" = "yes" ]; then
    results+="✓ Terminated leftover rclone daemon\n"
elif [ "${DAEMON_KILLED:-}" = "skipped" ]; then
    results+="⚠ Left rclone daemon running (user declined)\n"
elif [ -n "${DAEMON_PIDS:-}" ]; then
    results+="⚠ Daemon was present at start\n"
fi

if rclone config delete protondrive >/dev/null 2>&1; then results+="✓ Removed backend tokens\n"
else results+="• No backend tokens found\n"; fi

rm -rf "$HOME"/.cache/rclone/vfs/protondrive* \
       "$HOME"/.cache/rclone/vfsMeta/protondrive* 2>/dev/null
results+="✓ Removed VFS caches\n"

if [ -d "$MOUNTPOINT" ] && [ -z "$(ls -A "$MOUNTPOINT" 2>/dev/null)" ]; then
    rmdir "$MOUNTPOINT" && results+="✓ Removed mountpoint\n"
elif [ -d "$MOUNTPOINT" ]; then
    results+="⚠ Left $MOUNTPOINT in place (not empty — check manually)\n"
fi

if rm -f "$HOME/.local/state/proton-mount.log" 2>/dev/null; then results+="✓ Removed log\n"
else results+="• No log file found\n"; fi

# --- Remove app menu launchers ------------------------------------------------
if [ -f "$APPDIR/proton-drive.desktop" ] || \
   [ -f "$APPDIR/proton-drive-uninstall.desktop" ]; then
    rm -f "$APPDIR/proton-drive.desktop" \
          "$APPDIR/proton-drive-uninstall.desktop"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APPDIR" 2>/dev/null || true
    fi
    results+="✓ Removed app menu launchers\n"
else
    results+="• No app menu launchers found\n"
fi

# --- Finish --------------------------------------------------------------------
results+="\nAll proton-automount traces removed.\n\n"
results+="Note: the cloned repository folder itself (this script's\n"
results+="home) was NOT touched — delete it manually if you wish."
notify-send -u normal "Proton Drive" "Uninstall complete ✓" 2>/dev/null
msg_info "Proton Drive Uninstall" "$results"
echo -e "$results"
