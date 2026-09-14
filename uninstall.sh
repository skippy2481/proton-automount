#!/usr/bin/env bash
# Uninstaller for proton-automount
# Removes: saved credentials, rclone backend tokens, VFS caches,
# mountpoint, the log, and app menu launchers. Does NOT touch
# anything else in rclone.conf.
#
# Refuses to run while ~/ProtonDrive is mounted. Unmount first, then
# run the uninstaller again.

ENVFILE="$HOME/.config/proton-automount.env"
MOUNTPOINT="$HOME/ProtonDrive"
APPDIR="$HOME/.local/share/applications"

# --- Blocked while mounted -------------------------------------------------
if mountpoint -q "$MOUNTPOINT"; then
    if command -v kdialog >/dev/null 2>&1; then
        notify-send -u critical "Proton Drive Uninstall" \
            "Blocked — drive is mounted!" 2>/dev/null
        kdialog --title "Proton Drive Uninstall" --error \
"Cannot uninstall while Proton Drive is mounted!

Please unmount it first:
• In Dolphin: right-click ~/ProtonDrive → Unmount
• Or in a terminal: proton-automount.sh unmount

Then run this uninstaller again."
    else
        echo "ERROR: $MOUNTPOINT is mounted. Unmount it first" >&2
        echo "(Dolphin right-click → Unmount, or: proton-automount.sh unmount)," >&2
        echo "then re-run this uninstaller." >&2
    fi
    exit 1
fi
# --- Lingering daemon check ---------------------------------------------------
DAEMON_PIDS=$(pgrep -f "rclone.*mount.*$MOUNTPOINT" 2>/dev/null)
if [ -n "$DAEMON_PIDS" ]; then
    if command -v kdialog >/dev/null 2>&1; then
        if kdialog --title "Proton Drive Uninstall" --yesno \
"A leftover rclone process for this mount was found (no longer
mounted, but still running):

$DAEMON_PIDS

Terminate it before removing files? (recommended)"; then
            TERMINATE="yes"
        else
            TERMINATE="no"
        fi
    else
        read -rp "Leftover rclone daemon found (PIDs: $DAEMON_PIDS). Terminate it? [Y/n] " ans
        case "$ans" in [Nn]*) TERMINATE="no";; *) TERMINATE="yes";; esac
    fi

    if [ "$TERMINATE" = "yes" ]; then
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
if command -v kdialog >/dev/null 2>&1; then
    if ! kdialog --title "Proton Drive Uninstall" --yesno \
"This will remove ALL proton-automount data:

• Saved credentials ($ENVFILE)
• rclone backend tokens ([protondrive] in rclone.conf)
• VFS file caches (~/.cache/rclone/vfs*/protondrive*)
• Mountpoint directory ($MOUNTPOINT)
• Log (~/.local/state/proton-mount.log)
• App menu launchers (proton-drive*.desktop)

Remove everything now?"; then
        exit 0
    fi
else
    read -rp "Remove all proton-automount data? [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || exit 0
fi

# --- Removal ------------------------------------------------------------------
results=""

if rm -f "$ENVFILE" 2>/dev/null; then results+="✓ Removed credentials\n"
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
if command -v kdialog >/dev/null 2>&1; then
    notify-send -u normal "Proton Drive" "Uninstall complete ✓" 2>/dev/null
    kdialog --title "Proton Drive Uninstall" --msgbox "$results"
fi
echo -e "$results"
