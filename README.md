# archconfig

Packages, dotfiles, `/etc` files, services and scripts for my Arch machines and the Steam Deck. macOS counterpart: [macconfig](https://github.com/guitaripod/macconfig).

| Looking for | Go to |
|---|---|
| AUR packages | [`scripts/pkglist-aur.txt`](scripts/pkglist-aur.txt) |
| Official packages | [`scripts/pkglist-official.txt`](scripts/pkglist-official.txt) |
| System services | [`scripts/enabled-services.txt`](scripts/enabled-services.txt), x1carbon: [`enabled-services-x1carbon.txt`](scripts/enabled-services-x1carbon.txt) |
| User services and timers | [`home/.config/systemd/user/`](home/.config/systemd/user) |
| Dotfiles (mirrors `~`) | [`home/`](home) |
| System files (mirrors `/etc`) | [`etc/`](etc) |
| Commands | [Scripts](#scripts) |
| Steam launch options | [Steam](#steam-launch-options) |

## Fresh install

Needs multilib enabled in `/etc/pacman.conf` and an SSH key on GitHub: the scripts clone ThemeSwitch, Neovim, Ghostty and Claude Code configs over SSH.

```bash
git clone git@github.com:guitaripod/archconfig.git ~/dotfiles
~/dotfiles/scripts/install.sh
~/dotfiles/scripts/link.sh
reboot
```

- [`install.sh`](scripts/install.sh): packages, yay, oh-my-bash, `/etc` files, system services, ThemeSwitch build.
- [`link.sh`](scripts/link.sh): dotfiles, external config repos, scripts, user services. A real file it would symlink over is kept as `<name>.backup`; copied files (KDE, emulators, scripts) and a non-git `~/.config/nvim` or `~/.config/ghostty` are replaced.
- On arch, also `cargo install talteen` and `uv tool install github-backup`.

`install.sh` and `link.sh` branch on the hostname. The Deck has its own linker.

## Sync

Pull (on the Deck, `link-steamdeck.sh` instead of `link.sh`):

```bash
git -C ~/dotfiles pull && ~/dotfiles/scripts/link.sh
```

Push: most dotfiles are symlinks into the repo, so edits are already in `~/dotfiles`. KDE and emulator configs are copies (the apps replace symlinks); on arch or x1carbon, bring them back, plus the package lists on arch, with:

```bash
~/dotfiles/scripts/update-from-system.sh
```

Review `git diff`, then commit and push.

## Machines

| Host | Setup |
|---|---|
| `arch` | Desktop (NVIDIA). Everything. |
| `x1carbon` | ThinkPad. `install.sh` skips NVIDIA, gaming and server packages and installs fprintd with the fingerprint PAM files in [`etc/x1carbon/pam.d/`](etc/x1carbon/pam.d); enroll with `fprintd-enroll`. |
| `steamdeck` | SteamOS. Run [`link-steamdeck.sh`](scripts/link-steamdeck.sh), never `link.sh`: shell, git, SSH, terminal, editors, Claude Code and a few scripts. Packages go in Distrobox. |

## What's in it

| Area | Contents |
|---|---|
| Shell | bash with oh-my-bash, aliases |
| Editors | vim, Zed; Neovim from [rawdog.ml.nvim](https://github.com/guitaripod/rawdog.ml.nvim) |
| Terminal | btop; Ghostty from [ghostty-config](https://github.com/guitaripod/ghostty-config) |
| Desktop | KDE Plasma (theme, shortcuts, window rules), [ThemeSwitch](https://github.com/guitaripod/ThemeSwitch), circadia, mpv, MIME handlers |
| Keyboard | keyd: Ctrl+J/K as Down/Up, Caps Lock as Esc |
| Audio | PipeWire low-latency, Guitarix with Neural Amp Modeler |
| Emulators | RPCS3 with per-game configs, PCSX2, Dolphin, Cemu (arch) |
| Security | [LAN firewall table](etc/host-fw.nft), key-only sshd, kptr_restrict; tailnet-only Samba (arch) |
| Power | performance governor and NVIDIA power limit (arch) |
| AI agents | per-host [Claude Code rules](home/.claude/rules), [opencode](home/.config/opencode/machines) and [delegate](home/.config/delegate/machines) overlays; global config in [claudeconfig](https://github.com/guitaripod/claudeconfig) |
| Browser | [`apps/vivaldi-zoom-step`](apps/vivaldi-zoom-step), an unpacked Vivaldi extension loaded from this path; [FrankerFaceZ settings](apps/ffz-settings.json) |

## Scripts

`link.sh` (or `link-steamdeck.sh`) installs these to `~/.local/bin` without the extension.

| Command | Does | Hosts |
|---|---|---|
| [`guitar`](scripts/guitar.sh) | Guitarix on the Scarlett Solo; NAM profiles and IRs in `~/.local/share/guitar/` | all |
| [`tailsend`](scripts/tailsend.sh) | Taildrop the clipboard or selected files (Dolphin menu, launcher) | all |
| [`clip-to-twitter`](scripts/clip-to-twitter.sh) | Re-encode a clip for X, keeping 4K60 | all |
| [`toggle-perf`](scripts/toggle-perf.sh) | asusctl Quiet / Performance profile | any with asusctl |
| [`applink`](scripts/applink.sh) | Pick and paste an App Store link (with [`applink-picker`](scripts/applink-picker.py)) | arch, x1carbon |
| [`hdr-game`](scripts/hdr-game.sh) | HDR on the display only while a game runs | arch |
| [`game-cores`](scripts/game-cores.py) | Game on the P-cores, its helper threads on the E-cores | arch |
| [`swtor-autologin`](scripts/swtor-autologin.py) | Fill the SWTOR launcher password from 1Password | arch |
| [`steam-taskbar-icons`](scripts/steam-taskbar-icons.py) | Real taskbar icons for Steam games, on library change | arch |
| [`upscayl-watch`](scripts/upscayl-watch.py) | Upscale new pictures in watched folders | arch |
| [`github-mirror`](scripts/github-mirror.sh) | Mirror, back up and verify all GitHub repos (timers) | arch |
| [`ufc-rss-fetch`](scripts/ufc-rss-fetch.sh) | Queue new UFC releases from RSS in qBittorrent (timer) | arch, steamdeck |
| [`qbt-add`](scripts/qbt-add.sh) | Add magnets and torrent files to qBittorrent-nox | arch, steamdeck |
| [`obsbot-fix-whitebalance`](scripts/obsbot-fix-whitebalance.sh) | Reapply OBSBOT webcam white balance while the camera is in use | arch |

Run from the repo: `sudo scripts/gpu-power-sweep.sh` measures decode speed and watts per GPU power limit.

## Steam launch options

Baseline for GE-Proton (DLSS upgrade, MangoHud hidden until Left Ctrl+Right, OBS capture, keyd's virtual pointer and the mouse passthrough ignored as controllers):

```
PROTON_DLSS_UPGRADE=1 MANGOHUD_CONFIG=full,no_display,toggle_hud=Control_L+Right SDL_GAMECONTROLLER_IGNORE_DEVICES=0x0fac/0x1ade,0xbeef/0xdead mangohud obs-gamecapture %command%
```

On arch, put `hdr-game` and `game-cores` before `mangohud` for HDR and the P/E-core split.
