# Archconfig - Claude Code Instructions

This is the single source of truth for Arch Linux machine configuration.

## Principles

- Keep configs accurate to what's actually installed/used
- Remove anything unused immediately
- No redundancy, no bloat
- Push changes as soon as they're made

## Structure

```
scripts/
  install.sh              # Run on fresh machine (packages, services, oh-my-bash)
  link.sh                 # Symlinks dotfiles to home directory
  link-steamdeck.sh       # Deck-safe subset of link.sh (run this on steamdeck)
  update-from-system.sh   # Pull current system configs into repo
  guitar.sh               # Launch Guitarix with Scarlett Solo routing
  toggle-perf.sh          # Toggle performance mode
  pkglist-official.txt    # Arch official packages (pacman)
  pkglist-aur.txt         # AUR packages (yay)
  enabled-services.txt    # Systemd services to enable
home/                     # Dotfiles (mirrors ~/)
  home/.claude/rules/     # Arch-only Claude Code rules, linked into ~/.claude/rules/ (global config is claudeconfig)
etc/                      # System configs (mirrors /etc/)
  etc/keyd/               # Key remapping
  etc/default/cpupower-service.conf  # CPU governor (performance)
  etc/systemd/system/     # Custom systemd services
```

## Workflow

**Adding something new:**
1. Install/configure on machine
2. Add to relevant package list or config
3. Update link.sh if new dotfile
4. Commit and push to master

**Removing something:**
1. Remove from package lists and enabled-services.txt
2. Remove config files from home/ or etc/
3. Remove from link.sh
4. Commit and push to master

## External Config Repos

- `~/.config/ghostty` → `guitaripod/ghostty-config` (cloned by link.sh, not symlinked from this repo)
  - Per-machine overrides in `machines/<hostname>`, symlinked to `local` by link.sh

## Machines

- **arch** — main desktop, native Arch, uses install.sh + link.sh directly
- **steamdeck** — SteamOS (immutable root), packages go through Distrobox (`distrobox enter arch`), export apps/bins to host. Run `scripts/link-steamdeck.sh`, never `link.sh`: mainline enables units that do not exist here and clones over SSH, which this host has no authorized key for. The Deck linker takes shell/git/ssh/terminal/Claude configs only — KDE, emulators (EmuDeck owns them), pipewire, mimeapps and systemd units are deliberately skipped.
- **macbook** — macOS
- **g14** — Arch laptop
- **x1carbon** — ThinkPad X1 Carbon 7th gen (Intel-only); skip nvidia/lib32/gaming packages from pkglists when installing. Only machine with a fingerprint reader (Synaptics 06cb:00bd) — `etc/x1carbon/pam.d/` is installed only on this host. After enrolling with `fprintd-enroll`, the PAM files give fingerprint auth (with password fallback) for sudo, su, polkit, system-local-login, SDDM, and kscreenlocker.

## Rules

- Branch: master only
- Package lists: keep alphabetically sorted
- KDE configs: copy, don't symlink (KDE overwrites symlinks)
- Secrets: never commit API keys, tokens, or credentials
