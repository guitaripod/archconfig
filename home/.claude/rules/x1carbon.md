# This machine: x1carbon (ThinkPad X1 Carbon 7th gen, Arch laptop)

- Intel UHD 620, 7.4 GiB RAM, no swap, no NVIDIA/CUDA. There is no ollama, llama-swap or `opencode-serve` here; never point tools at `localhost:8081` or assume a GPU box.
- Desktop-only units (Plex, Docker, qBittorrent-nox, OBSBOT, UFC RSS, upscayl-watch, steam-taskbar-icons) are deliberately not installed or enabled. Keep taildrop, circadia, themeswitch and claudememory-sync.
- Machine overlays are `~/dotfiles/home/.config/opencode/machines/x1carbon.json` and `~/dotfiles/home/.config/delegate/machines/x1carbon.yml`; `link.sh` selects them by `/etc/hostname`. Arch-only rules (`arch.md`, `local-models.md`, `zvec-grep.md`) are not linked here.
- Package installs use `scripts/install.sh`, which filters arch-only packages and reads `scripts/enabled-services-x1carbon.txt`. Shared package lists are edited on arch only.
- SSH is key-only when `etc/ssh/sshd_config.d/10-hardening.conf` is installed; Tailscale is the remote path. Check `systemctl is-active sshd` before assuming remote access.
- Repos: `~/dotfiles` (this machine's config) and `~/claudeconfig` (shared Claude/opencode config).
