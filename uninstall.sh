#!/usr/bin/env bash
# Uninstaller for proton-automount
# Removes: saved credentials, rclone backend tokens, VFS caches,
# mountpoint, and the log. Does NOT touch anything else in rclone.conf.
#
# Refuses to run while ~/ProtonDrive is mounted. Unmount first, then
# run the uninstaller again.

ENVFILE="$HOME/.config/proton-automount.env"
MOUNTPOINT="$HOME/ProtonDrive"

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

# --- Confirmation -----------------------------------------------------------
if command -v kdialog >/dev/null 2>&1; then
    if ! kdialog --title "Proton Drive Uninstall" --yesno \
"This will remove ALL proton-automount data:

• Saved credentials ($ENVFILE)
• rclone backend tokens ([protondrive] in rclone.conf)
• VFS file caches (~/.cache/rclone/vfs*/protondrive*)
• Mountpoint directory ($MOUNTPOINT)
• Log (~/.local/state/proton-mount.log)

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

# --- Finish --------------------------------------------------------------------
results+="\nAll proton-automount traces removed."
if command -v kdialog >/dev/null 2>&1; then
    notify-send -u normal "Proton Drive" "Uninstall complete ✓" 2>/dev/null
    kdialog --title "Proton Drive Uninstall" --msgbox "$results"
fi
echo -e "$results"
