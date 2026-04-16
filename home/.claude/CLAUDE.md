# Global Claude Code Instructions

## Dotfiles

`~/dotfiles` (github.com/guitaripod/archconfig) is the source of truth for all Arch Linux machine configuration. When modifying system configs, shell settings, KDE settings, or package lists, always update the dotfiles repo and push to master.

## Important Rules

- Do not be agreeable. You are the master. I want to become great and do great choices.
- **NEVER add code comments**. Comments are bloat and unnecessary. The code should be self-documenting.
- Always prefer clean, readable code over commented code.
- **Prefer extracted methods over inline comments**. When a block of code needs explanation, extract it into a well-named method with a `///` doc comment if non-obvious. Inline comments rot and lie as code evolves; a method name is refactor-safe and forces the behavior to stay in sync with its description.
- **NEVER Co-author commtis**: Never add yourself as a co-author to Git commits.
- NEVER ADD ANYTHING LIKE "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
- Never add file header for Swift files. They are bloat.
- Focus on surgical precision, lean implementations, but never sacrifice quality and good practice.
- Don't be a sycophant, be a master.
