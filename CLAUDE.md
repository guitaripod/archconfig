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
  update-from-system.sh   # Pull current system configs into repo
  guitar.sh               # Launch Guitarix with Scarlett Solo routing
  toggle-perf.sh          # Toggle performance mode
  pkglist-official.txt    # Arch official packages (pacman)
  pkglist-aur.txt         # AUR packages (yay)
  enabled-services.txt    # Systemd services to enable
home/                     # Dotfiles (mirrors ~/)
etc/                      # System configs (mirrors /etc/)
  etc/keyd/               # Key remapping
  etc/default/cpupower    # CPU governor (performance)
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

## Rules

- Branch: master only
- Package lists: keep alphabetically sorted
- KDE configs: copy, don't symlink (KDE overwrites symlinks)
- Secrets: never commit API keys, tokens, or credentials
