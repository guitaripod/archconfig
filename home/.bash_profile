#
# ~/.bash_profile
#

[[ -f ~/.bashrc ]] && . ~/.bashrc

export PATH="$HOME/.cargo/bin:$PATH"

# Added by swiftly
[[ -f "$HOME/.local/share/swiftly/env.sh" ]] && . "$HOME/.local/share/swiftly/env.sh"
# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
