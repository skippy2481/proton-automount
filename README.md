# Proton Drive Auto-Mount for Linux (KDE Plasma)

Mount your Proton Drive as a local folder at `~/ProtonDrive` with **zero-persistence security** — no session tokens are ever left on disk after you unmount.

On first run, the script walks you through setup with simple popups. After that, mounting is one click (or one command) — your username and password are remembered, and you just supply the current 2FA code.

## Target environment

**KDE Plasma** desktops (uses `kdialog` for popups — ships with Plasma).

Tested on: **Ultramarine Linux 44 — KDE Plasma (Fedora 44 base)**, rclone v1.74.3. Should work on any Fedora-based Plasma setup. GNOME/zenity support is planned as a separate repo.

## How it works

| Moment | What happens |
|---|---|
| First run | Username + password wizard → saved to `~/.config/proton-automount.env` (mode 600) |
| Every mount thereafter | Credentials loaded from env file → **2FA step only** (YubiKey touch or TOTP popup) → mount |
| Drive mounted | The rclone daemon's session lives **in RAM only** — tokens are purged from disk |
| Unmount (Dolphin or script) | Stays unmounted. No background watcher. Nothing remounts until you run the script again |
| Account has no 2FA | Leave the TOTP popup empty — logs in with password only |

Between sessions, there are no valid session tokens anywhere on disk — every mount requires a genuine, current 2FA code (when 2FA is enabled on the account).

## Requirements

- rclone **v1.64.0 or newer** (that's when the Proton Drive backend was added)
- FUSE / fuse3
- `kdialog` (included with KDE Plasma)
- Optional: `ykman` (YubiKey automatic TOTP), `notify-send` (desktop notifications)

> ⚠️ Note: rclone has flagged the Proton Drive backend as **unmaintained**. Newer rclone versions can be hit-or-miss — tested working on v1.74.3.

## Install

```bash
./install.sh
```

Installs rclone, FUSE, ykman, and libnotify for your distro (dnf / apt / pacman / zypper detected automatically). `kdialog` is not installed — it ships with KDE Plasma. The installer also verifies your rclone version is ≥ 1.64.

Then make the scripts executable if needed:

```bash
chmod +x proton-automount.sh uninstall.sh
```

## First run

```bash
./proton-automount.sh
```

A popup asks for your Proton username:

![First-time setup — username prompt](username.png)

Then your password (input is hidden):

![First-time setup — password prompt](password-prompt.png)

Credentials are saved to `~/.config/proton-automount.env` with owner-only permissions (`600`) — verify after first run:

![Env file with 600 permissions](env-file-location.png)

You will then be asked for your 2FA code (see YubiKey section below, or type the code manually). The drive mounts at `~/ProtonDrive` and a notification confirms it.

## YubiKey automatic 2FA (optional)

If a YubiKey is plugged in, the script reads the current TOTP code straight off the key — you just touch it, no typing.

**One-time setup:** open `proton-automount.sh` in an editor and find the marked placeholder in `fetch_code()`:

![Editing the YubiKey credential placeholder](placeholder.png)

Find your credential's exact name:

```bash
ykman oath accounts list
```

(Example output: `Proton Mail:you@example.com`)

Then replace `<protonmail yubikey entry>` in the script with that exact name, case-sensitive, spaces included. **Without this edit**, the YubiKey path silently falls back to the manual TOTP popup.

Tip: the credential should have touch **enabled** (Yubico Authenticator app → credential → settings). The script waits 30 seconds for a touch and pops a dialog telling you to touch the key.

No YubiKey? Skip this entirely — you'll get a TOTP popup instead. No 2FA on your account at all? Leave the popup empty and it logs in with password only.

## Everyday use

- **Mount:** run `./proton-automount.sh` (or link it to a menu entry — see tip below). Touch your YubiKey or enter the current code. Done.
- **Unmount:** right-click `~/ProtonDrive` → Unmount in Dolphin, or run `./proton-automount.sh unmount`.
- **Remount:** just run the script again — username/password are remembered, only the 2FA step repeats.

Logs live at `~/.local/state/proton-mount.log` if anything ever misbehaves (includes rclone's own mount output).

## Tip: add a "Proton Drive" launcher to your app menu

Instead of opening a terminal to run the script, give yourself a clickable application-menu entry. Create this file:

```bash
nano ~/.local/share/applications/proton-drive.desktop
```

Paste this in (edit the `Exec=` line to the **absolute path** where you keep `proton-automount.sh`, and `Icon=` to wherever you keep an icon):

```ini
[Desktop Entry]
Type=Application
Name=Proton Drive
Comment=Mount your Proton Drive with 2FA
Exec=/home/YOURUSERNAME/bin/proton-automount.sh
Icon=/home/YOURUSERNAME/proton.png
Terminal=false
Categories=Network;FileTools;
```

Save, then it appears in your application launcher (may take a few seconds, or log out/in once). Since the script is GUI-driven (kdialog), `Terminal=false` is all you need — no terminal window opens.

To also get a launcher for unmounting, duplicate the file as `proton-drive-unmount.desktop` and change `Exec=` to end in `unmount`:

```ini
Exec=/home/YOURUSERNAME/bin/proton-automount.sh unmount
```

## Security model

The script enforces a strict credential lifecycle:

1. **Environment file** — your Proton username and password are saved once to `~/.config/proton-automount.env` with `600` permissions. They are loaded on every mount but never written to rclone.conf.

2. **At login start** — any cached `[protondrive]` section in `rclone.conf` (access/refresh tokens, salted key) is deleted. This *forces* a fresh login using the env file credentials + a current 2FA code. Without it, a previous session's cache would let *any* credentials mount again.

3. **During mount** — credentials are passed to rclone via environment variables (`RCLONE_CONFIG_PROTONDRIVE_*`) and `rclone obscure` is applied at runtime.

4. **After mount** — the `[protondrive]` section in `rclone.conf` is purged again within seconds of the mount coming up. The daemon keeps its session in memory only.

5. **On unmount** (via the script) — purged again.

Net effect: backend tokens exist on disk only for the brief login window. `rclone config delete` removes *only* the `[protondrive]` section — any other remotes you keep in `rclone.conf` are untouched.

**Honest limits of this design:**

- Your Proton **password** is stored in plaintext in `~/.config/proton-automount.env`, protected by `600` file permissions. That's the trade-off for "only 2FA on every remount." Use full-disk encryption (LUKS) if you need the file protected at rest.
- `rclone obscure` is used at runtime, but it's encoding, not encryption.
- If you unmount from Dolphin rather than the script, stale tokens sit inert in `rclone.conf` until the next script run purges them.

## ⚠️ Do NOT rm -rf through the mount

While `~/ProtonDrive` is mounted, it **is** your Proton Drive — not a copy. Deleting files through the mount deletes them from the cloud. A careless `rm -rf ~/ProtonDrive/*` while mounted destroys cloud data, likely permanently. Be careful with cleanup commands that match the mountpoint while it's mounted.

## Uninstall

```bash
./uninstall.sh
```

Works from a click or terminal. If the drive is mounted, the uninstaller refuses and tells you to unmount first:

![Uninstaller blocked while mounted](uninstall-blocked.png)

After confirming, it removes saved credentials, rclone backend tokens, VFS caches, the mountpoint, and the log — everything:

![Uninstall confirmation](uninstall-1.png)

![Uninstall complete](uninstall-2.png)

It only removes the `[protondrive]` section from `rclone.conf`, so other remotes are safe.

## Project files

| File | Purpose |
|---|---|
| `proton-automount.sh` | Mount script (run this) |
| `install.sh` | Dependency installer (dnf/apt/pacman/zypper) |
| `uninstall.sh` | Full cleanup / removal |

## Known limitations

- KDE Plasma only (`kdialog`) — GNOME version planned as a separate repo
- Each mount performs a full login (SRP + 2FA), which takes a few seconds longer than cached-credential mounts — that's intentional
- Repeated failed logins can hit Proton's rate limiting; wait a few minutes if you mistype your password/2FA several times

## License

MIT — see [LICENSE](LICENSE)
