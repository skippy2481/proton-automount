# Proton Drive Auto-Mount for Linux (rclone)

A bash script that keeps your Proton Drive mounted at `~/ProtonDrive`,
with an interactive 2FA fallback: if your session expires, a popup on your
desktop asks for a current TOTP code and remounts.

## Tested on
- Ultramarine Linux 44 — KDE Plasma (Fedora 44 base)

Only this exact setup has been verified. It should work on other
Fedora-based distributions and KDE Plasma desktops. On other desktop
environments you'll need to swap `kdialog` for your desktop's dialog tool
(e.g. `zenity` on GNOME) in the `ask_code()` function — the script doesn't
do this automatically.

## How it works
Every 5 minutes the script checks whether `~/ProtonDrive` is mounted.
If your session has expired, it pops up a dialog asking for a current
2FA TOTP code, then remounts.

## Requirements
- **rclone v1.64.0 or newer** — that's when the Proton Drive backend was
  added. Note: rclone has flagged this backend as unmaintained, so newer
  versions can be hit-or-miss; test after upgrading.
- FUSE / fuse3
- `kdialog` (shows the 2FA popup)
- Optional: `notify-send` (desktop notifications)

## Setup

**1. Install rclone and FUSE** (Fedora example):
```bash
sudo dnf install rclone fuse3
```

**2. Configure the remote** — in a terminal run:
```bash
rclone config
```
- Choose `n` (new remote), name it `protondrive` (must match the
  `REMOTE=` variable in the script)
- Storage type: `protondrive`
- Enter your Proton username
- Enter your Proton password
- When prompted, enter a current 2FA code to finish the setup

Test that it worked:
```bash
rclone lsd protondrive:
```

**3. Make the script executable and run it:**
```bash
chmod +x proton-automount.sh
./proton-automount.sh
```

On first run (or whenever your session has expired) a dialog box pops up
on your screen asking for your 2FA TOTP code — enter the current code from
your authenticator app and it mounts. After that, the script re-checks
every 5 minutes and remounts silently as long as the session is alive.

## Optional: automatic 2FA via YubiKey (UNTESTED)

The script contains a code path that reads a TOTP code straight off a
plugged-in YubiKey via `ykman`, skipping the popup entirely:

- `ykman` must be installed and a YubiKey plugged in
- The key must have a TOTP/OATH credential named `ProtonMail`
  (check with `ykman oath accounts list` and rename in `fetch_code()`
  if yours differs)
- The credential should have **touch disabled** — with touch required,
  `ykman` would stall invisibly instead of falling back to the popup

⚠️ This path is untested — only the kdialog popup flow has been verified
in practice. If the YubiKey read fails for any reason, the script falls
back to the popup anyway.

## Notes
- Credentials live in `~/.config/rclone/rclone.conf` — never commit that
  file anywhere.
- The script logs to `~/.local/state/proton-mount.log`.
