#!/usr/bin/env bash
set -euo pipefail

# Plug-and-Play installer & uninstaller for javaCardAuth (myOs + generic Ubuntu-based distros)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER_BEGIN="# >>> javaCardAuth >>>"
MARKER_END="# <<< javaCardAuth <<<"
PAM_RULE_REGEX='pam_ssh_agent_auth\.so'
PAM_RULE_LINE='auth	sufficient	pam_ssh_agent_auth.so file=/etc/security/authorized_keys'

DRY_RUN=false
UNINSTALL=false
MODE="auto"
EXPLICIT_USER=""
SKIP_PACKAGES=false
SKIP_PAM=false
FORCE_PAM_OVER_SSH=false
AUTH_KEY_FILE=""
EXPORT_AUTH_KEY=false
ENABLE_CONFIRM=false
DISABLE_GCR_SSH_AGENT=false
WITH_NVIM=false
FORCE=false

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Plug-and-Play setup for SmartPGP JavaCard (SSH, Git signing, sudo PAM, .env.gpg).
Supports both myOs (Stow dotfiles) and generic Ubuntu-based distributions.

Options:
  --dry-run                Print planned actions without modifying files or system state
  --mode auto|myos|generic Select integration mode (default: auto)
  --user <username>        Target non-root user when invoked from a root shell
  --skip-packages          Skip apt-get package installation
  --skip-pam               Skip /etc/sudoers.d/ssh-agent, authorized_keys, and /etc/pam.d/sudo*
  --force-pam-over-ssh     Allow PAM edits even when SSH_CONNECTION is set
  --auth-key-file <path>   SSH public key file to install into /etc/security/authorized_keys
  --export-auth-key        Export current `ssh-add -L` public key into /etc/security/authorized_keys
  --enable-confirm         Add current card AUTH keygrip with `0 confirm` to ~/.gnupg/sshcontrol
  --disable-gcr-ssh-agent  Disable GNOME gcr-ssh-agent.{socket,service} to avoid socket hijacking
  --with-nvim              Install nvimGpgGuard.lua into ~/.config/nvim/plugin/
  --force                  Backup and overwrite existing unmanaged ~/.gnupg or config files
  --uninstall              Revert installed blocks, binary, sudoers, and PAM rules (keeps keys/user configs)
  -h, --help               Show this help message
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --uninstall) UNINSTALL=true ;;
        --mode)
            if (( $# < 2 )); then
                echo "[ERROR] --mode requires an argument (auto|myos|generic)." >&2
                exit 1
            fi
            MODE="$2"
            shift
            ;;
        --user)
            if (( $# < 2 )); then
                echo "[ERROR] --user requires a username." >&2
                exit 1
            fi
            EXPLICIT_USER="$2"
            shift
            ;;
        --skip-packages) SKIP_PACKAGES=true ;;
        --skip-pam) SKIP_PAM=true ;;
        --force-pam-over-ssh) FORCE_PAM_OVER_SSH=true ;;
        --auth-key-file)
            if (( $# < 2 )); then
                echo "[ERROR] --auth-key-file requires a path." >&2
                exit 1
            fi
            AUTH_KEY_FILE="$2"
            shift
            ;;
        --export-auth-key) EXPORT_AUTH_KEY=true ;;
        --enable-confirm) ENABLE_CONFIRM=true ;;
        --disable-gcr-ssh-agent) DISABLE_GCR_SSH_AGENT=true ;;
        --with-nvim) WITH_NVIM=true ;;
        --force) FORCE=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

case "$MODE" in
    auto|myos|generic) ;;
    *)
        echo "[ERROR] Invalid --mode '$MODE' (expected auto, myos, or generic)." >&2
        exit 1
        ;;
esac

if [[ -n "$EXPLICIT_USER" ]]; then
    TARGET_USER="$EXPLICIT_USER"
elif (( EUID == 0 )) && [[ -z "${SUDO_USER:-}" ]]; then
    echo "[ERROR] Running directly as root without SUDO_USER; pass --user <username> explicitly." >&2
    exit 1
else
    TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
fi

if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "[ERROR] Target user '$TARGET_USER' does not exist." >&2
    exit 1
fi
TARGET_UID="$(id -u "$TARGET_USER")"
if (( EUID != 0 )) && [[ -z "$EXPLICIT_USER" ]] && [[ -n "${HOME:-}" && -d "$HOME" ]]; then
    TARGET_HOME="$HOME"
else
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
fi
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    echo "[ERROR] Home directory for '$TARGET_USER' not found: '${TARGET_HOME:-empty}'." >&2
    exit 1
fi
CONFIG_DIR="$TARGET_HOME/.config/javacard-auth"
STATE_DIR="$TARGET_HOME/.local/state/javacard-auth"
GNUPG_DIR="$TARGET_HOME/.gnupg"

run_cmd() {
    if $DRY_RUN; then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

run_root() {
    if (( EUID == 0 )); then
        run_cmd "$@"
    else
        run_cmd sudo "$@"
    fi
}

run_as_target() {
    if (( EUID == 0 )) && [[ "$TARGET_USER" != "root" ]]; then
        run_cmd sudo -u "$TARGET_USER" "$@"
    else
        run_cmd "$@"
    fi
}

run_user_systemctl() {
    local runtime_dir="/run/user/$TARGET_UID"
    local bus_addr="unix:path=$runtime_dir/bus"
    if [[ ! -S "$runtime_dir/bus" ]]; then
        echo "[WARN] User D-Bus session not active at $runtime_dir/bus; skipping: systemctl --user $*"
        return 1
    fi
    if (( EUID == 0 )) && [[ "$TARGET_USER" != "root" ]]; then
        run_cmd sudo -u "$TARGET_USER" \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
            systemctl --user "$@"
    else
        run_cmd env \
            XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
            systemctl --user "$@"
    fi
}

detect_mode() {
    if [[ "$MODE" != "auto" ]]; then
        echo "$MODE"
        return 0
    fi
    if [[ -d "$TARGET_HOME/myOs/dotfiles/gnupg" ]]; then
        echo "myos"
        return 0
    fi
    if [[ -L "$GNUPG_DIR/gpg-agent.conf" ]] && [[ "$(readlink -f "$GNUPG_DIR/gpg-agent.conf" 2>/dev/null || true)" == *"/myOs/"* ]]; then
        echo "myos"
        return 0
    fi
    echo "generic"
}

check_distro() {
    if [[ ! -r /etc/os-release ]]; then
        echo "[WARN] /etc/os-release not readable; OS compatibility cannot be verified."
        return 0
    fi
    local os_info
    os_info="$(
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}|${ID_LIKE:-}|${VERSION_CODENAME:-}"
    )"
    local id="${os_info%%|*}"
    local rest="${os_info#*|}"
    local id_like="${rest%%|*}"
    local codename="${rest#*|}"
    echo "[INFO] Detected OS: id=$id id_like=$id_like codename=$codename"
    if [[ "$id" != "ubuntu" && "$id" != "debian" && "$id_like" != *ubuntu* && "$id_like" != *debian* ]]; then
        echo "[WARN] Non-Ubuntu/Debian distribution detected ($id); package names and PAM paths may differ."
    fi
}

remove_marked_block() {
    local target_file="$1"
    if [[ -L "$target_file" ]]; then
        echo "[WARN] Skipping symlink $target_file during block removal."
        return 0
    fi
    [[ -f "$target_file" ]] || return 0
    if ! grep -Fq "$MARKER_BEGIN" "$target_file"; then
        return 0
    fi
    if $DRY_RUN; then
        echo "[DRY-RUN] Remove $MARKER_BEGIN ... $MARKER_END block from $target_file"
        return 0
    fi
    # shellcheck disable=SC2016
    run_as_target bash -c '
        tmp_file="$(mktemp)"
        awk -v begin="$1" -v end="$2" "
            \$0 == begin { skip = 1; next }
            \$0 == end { skip = 0; next }
            !skip { print }
        " "$3" > "$tmp_file"
        mv -f "$tmp_file" "$3"
    ' _ "$MARKER_BEGIN" "$MARKER_END" "$target_file"
}

append_marked_block() {
    local target_file="$1"
    if [[ -L "$target_file" ]]; then
        echo "[ERROR] Refusing to modify symlink $target_file in generic mode." >&2
        return 1
    fi
    if [[ ! -f "$target_file" ]]; then
        run_as_target touch "$target_file"
    fi
    if grep -Fq "$MARKER_BEGIN" "$target_file" 2>/dev/null; then
        echo "[INFO] Profile block already present in $target_file"
        return 0
    fi
    if $DRY_RUN; then
        echo "[DRY-RUN] Append javaCardAuth profile block to $target_file"
        return 0
    fi
    # shellcheck disable=SC2016
    run_as_target bash -c '
        {
            printf "\n%s\n" "$1"
            printf "%s\n" '\''if [ -f "$HOME/.config/javacard-auth/profile.sh" ]; then'\''
            printf "%s\n" '\''    . "$HOME/.config/javacard-auth/profile.sh"'\''
            printf "%s\n" '\''fi'\''
            printf "%s\n" "$2"
        } >> "$3"
    ' _ "$MARKER_BEGIN" "$MARKER_END" "$target_file"
}

install_user_file_with_backup() {
    local src="$1"
    local dst="$2"
    local file_mode="$3"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local backup_dir="$STATE_DIR/backups/$ts"

    if [[ -L "$dst" ]] && ! $FORCE; then
        echo "[INFO] Preserving symlinked file $dst (use --force to override)"
        return 0
    fi
    if [[ -f "$dst" ]]; then
        if cmp -s "$src" "$dst"; then
            echo "[INFO] $dst already up to date"
            return 0
        fi
        if ! $FORCE; then
            echo "[WARN] $dst differs from template; keeping existing file (use --force to backup and overwrite)"
            return 0
        fi
        run_as_target mkdir -p "$backup_dir"
        run_as_target cp -a "$dst" "$backup_dir/$(basename "$dst").bak"
    fi
    run_as_target install -Dm"$file_mode" "$src" "$dst"
}

select_pinentry_packages() {
    local pkgs=()
    local desktop="${XDG_CURRENT_DESKTOP:-}"
    local desktop_lower="${desktop,,}"
    local has_display=false
    if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
        has_display=true
    fi

    if ! command -v pinentry-curses >/dev/null 2>&1; then
        pkgs+=(pinentry-curses)
    fi

    if $has_display; then
        if [[ "$desktop_lower" == *gnome* || "$desktop_lower" == *ubuntu* || "$desktop_lower" == *unity* || "$desktop_lower" == *cinnamon* || "$desktop_lower" == *mate* || "$desktop_lower" == *xfce* ]]; then
            if ! command -v pinentry-gnome3 >/dev/null 2>&1; then
                pkgs+=(pinentry-gnome3)
            fi
        else
            if ! command -v pinentry-qt >/dev/null 2>&1; then
                pkgs+=(pinentry-qt)
            fi
        fi
    fi

    if (( ${#pkgs[@]} > 0 )); then
        printf '%s\n' "${pkgs[@]}"
    fi
}

find_pam_module() {
    local p
    for p in \
        /lib/*/security/pam_ssh_agent_auth.so \
        /usr/lib/*/security/pam_ssh_agent_auth.so \
        /lib/security/pam_ssh_agent_auth.so \
        /usr/lib/security/pam_ssh_agent_auth.so; do
        if [[ -f "$p" ]]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

do_uninstall() {
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    echo "=== [javaCardAuth UNINSTALL] ==="

    remove_marked_block "$TARGET_HOME/.profile"
    remove_marked_block "$TARGET_HOME/.bashrc"

    if [[ -f "$TARGET_HOME/.config/nvim/plugin/nvimGpgGuard.lua" ]]; then
        run_as_target rm -f "$TARGET_HOME/.config/nvim/plugin/nvimGpgGuard.lua"
    fi

    if [[ -f /usr/local/bin/pinentry-labeled ]]; then
        run_root rm -f /usr/local/bin/pinentry-labeled
    fi

    if [[ -f /etc/sudoers.d/ssh-agent ]]; then
        run_root rm -f /etc/sudoers.d/ssh-agent
    fi

    for pam_file in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
        if [[ -f "$pam_file" ]] && grep -Fq "$MARKER_BEGIN" "$pam_file"; then
            run_root mkdir -p /var/backups/javacard-auth
            run_root cp -a "$pam_file" "/var/backups/javacard-auth/$(basename "$pam_file").$ts.bak"
            if $DRY_RUN; then
                echo "[DRY-RUN] Remove javaCardAuth PAM block from $pam_file"
            else
                # shellcheck disable=SC2016
                run_root bash -c '
                    tmp_file="$(mktemp)"
                    awk -v begin="$1" -v end="$2" "
                        \$0 == begin { skip = 1; next }
                        \$0 == end { skip = 0; next }
                        !skip { print }
                    " "$3" > "$tmp_file"
                    chmod --reference="$3" "$tmp_file"
                    mv -f "$tmp_file" "$3"
                ' _ "$MARKER_BEGIN" "$MARKER_END" "$pam_file"
            fi
        fi
    done

    if [[ -f "$STATE_DIR/gcr-disabled" ]]; then
        local was_enabled
        was_enabled="$(cat "$STATE_DIR/gcr-disabled" 2>/dev/null || echo "0")"
        run_user_systemctl unmask gcr-ssh-agent.socket gcr-ssh-agent.service || true
        if [[ "$was_enabled" == "1" ]]; then
            run_user_systemctl enable --now gcr-ssh-agent.socket || true
        fi
        run_as_target rm -f "$STATE_DIR/gcr-disabled"
    fi

    echo "[INFO] Uninstall complete."
    echo "[INFO] Preserved user GnuPG directory ($GNUPG_DIR), /etc/security/authorized_keys, and ~/.config/javacard-auth/{labels.conf,gpg-recipients}."
    exit 0
}

if $UNINSTALL; then
    do_uninstall
fi

ACTIVE_MODE="$(detect_mode)"
echo "=== [1/6] Preflight (mode=$ACTIVE_MODE, user=$TARGET_USER, dry_run=$DRY_RUN) ==="
check_distro

if ! $SKIP_PACKAGES; then
    echo "=== [2/6] Installing required packages ==="
    PKGS=(gnupg scdaemon pcscd libccid opensc)
    if ! $SKIP_PAM; then
        PKGS+=(libpam-ssh-agent-auth)
    fi
    mapfile -t PIN_PKGS < <(select_pinentry_packages)
    if (( ${#PIN_PKGS[@]} > 0 )); then
        PKGS+=("${PIN_PKGS[@]}")
    fi
    echo "[INFO] Packages to ensure: ${PKGS[*]}"
    run_root apt-get update
    run_root apt-get install -y "${PKGS[@]}"
else
    echo "=== [2/6] Skipping package installation (--skip-packages) ==="
fi

echo "=== [3/6] Enabling smartcard and gpg-agent services ==="
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files pcscd.socket >/dev/null 2>&1; then
        run_root systemctl enable --now pcscd.socket || echo "[WARN] Could not enable/start pcscd.socket"
    else
        echo "[WARN] pcscd.socket unit not found yet (install pcscd first)."
    fi
    run_user_systemctl enable --now gpg-agent.socket gpg-agent-ssh.socket || true

    if $DISABLE_GCR_SSH_AGENT; then
        if systemctl --user list-unit-files gcr-ssh-agent.socket >/dev/null 2>&1; then
            GCR_WAS_ENABLED="0"
            if run_user_systemctl is-enabled gcr-ssh-agent.socket >/dev/null 2>&1 || run_user_systemctl is-active gcr-ssh-agent.socket >/dev/null 2>&1; then
                GCR_WAS_ENABLED="1"
            fi
            if run_user_systemctl disable --now gcr-ssh-agent.socket gcr-ssh-agent.service && run_user_systemctl mask gcr-ssh-agent.socket gcr-ssh-agent.service; then
                run_as_target mkdir -p "$STATE_DIR"
                if $DRY_RUN; then
                    echo "[DRY-RUN] Record gcr-disabled state ($GCR_WAS_ENABLED) at $STATE_DIR/gcr-disabled"
                else
                    # shellcheck disable=SC2016
                    run_as_target bash -c 'printf "%s\n" "$1" > "$2"' _ "$GCR_WAS_ENABLED" "$STATE_DIR/gcr-disabled"
                fi
            else
                echo "[WARN] Failed to disable/mask gcr-ssh-agent.socket cleanly; marker not recorded."
            fi
        fi
    elif systemctl --user is-active --quiet gcr-ssh-agent.socket 2>/dev/null; then
        echo "[WARN] GNOME gcr-ssh-agent.socket is active and may override SSH_AUTH_SOCK."
        echo "[WARN] Re-run with --disable-gcr-ssh-agent if SSH uses the wrong agent."
    fi
fi

echo "=== [4/6] Installing pinentry-labeled and user configuration ==="
run_root install -Dm755 -o root -g root "$SCRIPT_DIR/bin/pinentry-labeled" /usr/local/bin/pinentry-labeled

run_as_target mkdir -p -m 700 "$CONFIG_DIR"
run_as_target install -Dm644 "$SCRIPT_DIR/shell/profile.sh" "$CONFIG_DIR/profile.sh"
run_as_target install -Dm644 "$SCRIPT_DIR/shell/envHelpers.sh" "$CONFIG_DIR/envHelpers.sh"
run_as_target install -Dm644 "$SCRIPT_DIR/config/labels.conf.example" "$CONFIG_DIR/labels.conf.example"
run_as_target install -Dm600 "$SCRIPT_DIR/config/gpg-recipients.example" "$CONFIG_DIR/gpg-recipients.example"
if [[ ! -f "$CONFIG_DIR/labels.conf" ]]; then
    run_as_target cp -n "$CONFIG_DIR/labels.conf.example" "$CONFIG_DIR/labels.conf" || true
fi

if [[ -L "$GNUPG_DIR" ]]; then
    echo "[ERROR] $GNUPG_DIR is a symlink (tree-folding risk for private keys)." >&2
    echo "[ERROR] Unfold $GNUPG_DIR into a real 0700 directory before running install.sh." >&2
    exit 1
fi
run_as_target mkdir -p -m 700 "$GNUPG_DIR"
run_as_target chmod 700 "$GNUPG_DIR"

if [[ "$ACTIVE_MODE" == "myos" ]]; then
    echo "[INFO] myOs mode detected: preserving Stow-managed ~/.gnupg and ~/.profile symlinks."
    for expected in "$GNUPG_DIR/gpg-agent.conf" "$GNUPG_DIR/scdaemon.conf" "$TARGET_HOME/.profile"; do
        if [[ ! -e "$expected" ]]; then
            echo "[WARN] Expected myOs file missing: $expected (run ~/myOs/bootstrap.sh if needed)."
        fi
    done
else
    install_user_file_with_backup "$SCRIPT_DIR/config/gnupg/gpg-agent.conf" "$GNUPG_DIR/gpg-agent.conf" 600
    install_user_file_with_backup "$SCRIPT_DIR/config/gnupg/scdaemon.conf" "$GNUPG_DIR/scdaemon.conf" 644
    install_user_file_with_backup "$SCRIPT_DIR/config/gnupg/sshcontrol.example" "$GNUPG_DIR/sshcontrol.example" 600
    append_marked_block "$TARGET_HOME/.profile"
    if [[ -f "$TARGET_HOME/.bashrc" ]]; then
        append_marked_block "$TARGET_HOME/.bashrc"
    fi
fi

if $WITH_NVIM; then
    run_as_target install -Dm644 "$SCRIPT_DIR/nvimGpgGuard.lua" "$TARGET_HOME/.config/nvim/plugin/nvimGpgGuard.lua"
fi

if $ENABLE_CONFIRM; then
    AUTH_GRIP="$(run_as_target gpg --with-colons --with-keygrip -K 2>/dev/null | awk -F: '
        $1 == "ssb" && $12 ~ /a/ { want=1; next }
        want && $1 == "grp" { print $10; want=0 }
    ' | head -n 1 || true)"
    if [[ -n "$AUTH_GRIP" ]]; then
        if [[ ! -f "$GNUPG_DIR/sshcontrol" ]]; then
            if $DRY_RUN; then
                echo "[DRY-RUN] Create $GNUPG_DIR/sshcontrol with $AUTH_GRIP 0 confirm"
            else
                install -m 600 /dev/null "$GNUPG_DIR/sshcontrol"
                printf '%s 0 confirm\n' "$AUTH_GRIP" > "$GNUPG_DIR/sshcontrol"
                if (( EUID == 0 )) && [[ "$TARGET_USER" != "root" ]]; then
                    chown "$TARGET_USER:$TARGET_USER" "$GNUPG_DIR/sshcontrol"
                fi
            fi
        elif ! grep -q "$AUTH_GRIP" "$GNUPG_DIR/sshcontrol"; then
            if $DRY_RUN; then
                echo "[DRY-RUN] Append '$AUTH_GRIP 0 confirm' to $GNUPG_DIR/sshcontrol"
            else
                printf '%s 0 confirm\n' "$AUTH_GRIP" >> "$GNUPG_DIR/sshcontrol"
            fi
        else
            echo "[INFO] AUTH keygrip already present in $GNUPG_DIR/sshcontrol"
        fi
    else
        echo "[WARN] Could not detect AUTH keygrip via gpg -K; skipping --enable-confirm."
    fi
fi

echo "=== [5/6] Configuring sudo/sudo-rs PAM + sudoers SSH_AUTH_SOCK ==="
if $SKIP_PAM; then
    echo "[INFO] Skipping PAM setup (--skip-pam)."
elif [[ -n "${SSH_CONNECTION:-}" ]] && ! $FORCE_PAM_OVER_SSH; then
    echo "[WARN] Running over SSH; skipping PAM/sudoers modifications (use --force-pam-over-ssh to override)."
else
    AUTH_KEYS_DEST="/etc/security/authorized_keys"
    if [[ -n "$AUTH_KEY_FILE" ]]; then
        if [[ ! -s "$AUTH_KEY_FILE" ]]; then
            echo "[ERROR] --auth-key-file '$AUTH_KEY_FILE' is missing or empty." >&2
            exit 1
        fi
        run_root install -Dm644 -o root -g root "$AUTH_KEY_FILE" "$AUTH_KEYS_DEST"
    elif $EXPORT_AUTH_KEY; then
        TMP_AUTH_KEY="$(mktemp)"
        trap 'rm -f "$TMP_AUTH_KEY"' EXIT
        if ! SSH_AUTH_SOCK="$(run_as_target gpgconf --list-dirs agent-ssh-socket 2>/dev/null || echo "${SSH_AUTH_SOCK:-}")" ssh-add -L 2>/dev/null > "$TMP_AUTH_KEY" || [[ ! -s "$TMP_AUTH_KEY" ]]; then
            echo "[ERROR] --export-auth-key failed: ssh-add -L returned no public keys (insert JavaCard and import public key first)." >&2
            exit 1
        fi
        run_root install -Dm644 -o root -g root "$TMP_AUTH_KEY" "$AUTH_KEYS_DEST"
    fi

    if [[ ! -s "$AUTH_KEYS_DEST" ]]; then
        echo "[WARN] $AUTH_KEYS_DEST does not exist or is empty."
        echo "[WARN] Skipping PAM activation to avoid broken configuration. Export key with:"
        echo "       ssh-add -L > /tmp/card.pub && sudo ./install.sh --auth-key-file /tmp/card.pub"
    else
        run_root install -Dm440 -o root -g root "$SCRIPT_DIR/config/sudoers.d/ssh-agent" /etc/sudoers.d/ssh-agent
        if ! run_root visudo -cf /etc/sudoers.d/ssh-agent; then
            echo "[ERROR] visudo check failed for /etc/sudoers.d/ssh-agent; deleting it immediately." >&2
            run_root rm -f /etc/sudoers.d/ssh-agent
            exit 1
        fi

        if ! find_pam_module >/dev/null 2>&1; then
            if $DRY_RUN; then
                echo "[DRY-RUN] Would verify pam_ssh_agent_auth.so before updating /etc/pam.d/sudo*"
            else
                echo "[ERROR] pam_ssh_agent_auth.so not found; install libpam-ssh-agent-auth first." >&2
                exit 1
            fi
        fi

        PAM_TS="$(date +%Y%m%d-%H%M%S)"
        PAM_UPDATED=false
        for pam_file in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
            [[ -f "$pam_file" ]] || continue
            if ! grep -Eq '^@include[[:space:]]+common-auth([[:space:]]|$)' "$pam_file"; then
                echo "[WARN] $pam_file has no '@include common-auth' line; skipping to preserve password fallback."
                continue
            fi
            if grep -qE "$PAM_RULE_REGEX" "$pam_file"; then
                echo "[INFO] $pam_file already contains pam_ssh_agent_auth.so"
                continue
            fi
            run_root mkdir -p /var/backups/javacard-auth
            run_root cp -a "$pam_file" "/var/backups/javacard-auth/$(basename "$pam_file").$PAM_TS.bak"
            if $DRY_RUN; then
                echo "[DRY-RUN] Insert javaCardAuth PAM block before @include common-auth in $pam_file"
            else
                # shellcheck disable=SC2016
                run_root bash -c '
                    tmp_file="$(mktemp)"
                    awk -v begin="$1" -v rule="$2" -v end="$3" "
                        !inserted && /^@include[[:space:]]+common-auth([[:space:]]|$)/ {
                            print begin
                            print rule
                            print end
                            inserted = 1
                        }
                        { print }
                    " "$4" > "$tmp_file"
                    chmod --reference="$4" "$tmp_file"
                    mv -f "$tmp_file" "$4"
                ' _ "$MARKER_BEGIN" "$PAM_RULE_LINE" "$MARKER_END" "$pam_file"
                PAM_UPDATED=true
            fi
        done

        if $PAM_UPDATED; then
            echo "[IMPORTANT] Keep an emergency root shell open and verify password fallback now:"
            echo "            SSH_AUTH_SOCK=\"\" sudo -k true"
        fi
    fi
fi

echo "=== [6/6] Reloading gpg-agent ==="
if command -v gpgconf >/dev/null 2>&1; then
    run_as_target gpgconf --kill gpg-agent || true
fi

echo "[OK] Setup complete. Run ./doctor.sh to verify all checks."
