# Codemap — labels

Canonical labels (`./backup.sh --list-labels`). Keep this table aligned when adding apps.

| Label | Backup fn (backup.sh) | Restore notes | Parts builder |
|-------|----------------------|---------------|---------------|
| `hermes` | `backup_hermes` | rsync → `~/.hermes` | `parts_hermes` |
| `hermes-ui` | `backup_hermes_ui` | `home/` or legacy | generic / home |
| `chromium` | `backup_chromium` | `home/` + legacy map | `parts_chromium` |
| `zen` | `backup_zen` | `home/` + legacy map | `parts_zen` |
| `dms` | `backup_dms` | DankMaterialShell + quickshell | home / generic |
| `telegram` | `backup_telegram` | custom share dirs + flatpak + home | `parts_telegram` |
| `discord` | `backup_discord` | home + optional flatpak | home |
| `spotify` | `backup_spotify` | spotify + spicetify | `parts_spotify` |
| `inav` | `backup_inav` | `INAVConfigurator` dir | special-case in discover |
| `kdeconnect` | `backup_kdeconnect` | home + caches | home |
| `claude` | `backup_claude` | `~/.claude` | home |
| `antigravity` | `backup_antigravity` | multiple IDE paths | home |
| `cursor` | `backup_cursor` | `.cursor` + `.config/Cursor` | `parts_cursor` |
| `konsole` | `backup_konsole` | config + share | home |
| `heroic` | `backup_heroic` | no game prefixes | home |
| `steam` | `backup_steam` | login/config only, no steamapps | `parts_steam` |
| `system` | `backup_system_extras` | ssh, gpg, nss, keyrings, NM, … | `parts_system` |
| `system-root` | `backup_root_etc` | `/etc`, `/var/lib` (sudo) | `parts_system_root` |
| `secrets` | `backup_secrets` | `~/.secrets` file or dir | `parts_secrets` |
| `extras-gemini` | via `backup_gemini_codex` | `~/.gemini` | home children |
| `extras-codex` | via `backup_gemini_codex` | `~/.codex` | home children |
| `extras-agents` | via `backup_gemini_codex` | agent harness dirs | `parts_extras_agents` |
| `mempalace` | `backup_mempalace` | SQLite/chroma; stop daemon on restore | `parts_mempalace` |
| `tailscale` | `backup_tailscale` | status/env; manual re-auth | `parts_tailscale` |
| `packages` | `backup_package_state` | pacman/paru lists → reinstall | `parts_packages` |
| `shell-dots` | `backup_shell_dots` | bash/zsh/fish/starship | home / generic |
| `hyprland` | `backup_hyprland` | hypr + waybar/wlogout/wofi/rofi/fuzzel | home / generic |
| `illogical-impulse` | `backup_illogical_impulse` | theming bundle | home / generic |
| `matugen-colors` | `backup_matugen_colors` | matugen config | home / generic |
| `kde-theme` | `backup_kde_theme` | plasma/kdeglobals/qt5ct/qt6ct/… | home / generic |
| `gtk-theme` | `backup_gtk_theme` | gtk-3/4, ~/.themes, ~/.icons | home / generic |
| `desktop-entries` | `backup_desktop_entries` | applications + mimeapps + autostart | home / generic |
| `git-config` | `backup_git_config` | `.gitconfig`, `.config/git`, `gh` | home / generic |
| `mpv` | `backup_mpv` | `.config/mpv` | home / generic |
| `mangohud` | `backup_mangohud` | `.config/MangoHud` | home / generic |
| `gaming-overlays` | `backup_gaming_overlays` | vkBasalt/gamescope/cava/goverlay | home / generic |
| `input-remapper` | `backup_input_remapper` | input-remapper configs | home / generic |
| `fonts` | `backup_fonts` | user fonts + fontconfig | home / generic |
| `audio-config` | `backup_audio_config` | pipewire/pulse/wireplumber | home / generic |
| `klipper` | `backup_klipper` | clipboard history | home / generic |
| `yubico` | `backup_yubico` | YubiKey configs | home / generic |
| `nvim` | `backup_nvim` | nvim/vim configs (not plugin caches) | home / generic |
| `vscode` | `backup_vscode` | Code / Code - OSS (no caches) | home / generic |
| `terminals` | `backup_terminals` | alacritty/kitty/foot/ghostty/wezterm | home / generic |
| `firefox` | `backup_firefox` | `.mozilla` minus caches | home / generic |
| `keepassxc` | `backup_keepassxc` | KeePassXC settings | home / generic |
| `paru` | `backup_paru` | paru + yay config | home / generic |
| `cfg-*` | `backup_extra_apps` | GUI-discovered apps via `--extra-apps` | home / generic |

## Adding a label (checklist)

1. Append to `ALL_LABELS` in **both** `backup.sh` and `restore.sh`.
2. Implement `backup_<label>` using `sync_one` where possible; call `hash_label`.
3. Add `run_label <label> backup_<label>` in the main block.
4. Add a `restore_label` case (prefer `restore_home_tree`).
5. Add `FRIENDLY` / `FRIENDLY_LABEL` entries in GUI + parts module.
6. Add `parts_<label>` + `PART_BUILDERS` entry if you need finer than `label/all`.
7. Update README “What it backs up” and this table.
8. Run `diff <(./backup.sh --list-labels) <(./restore.sh --list-labels)`.
