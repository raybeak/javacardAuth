#!/usr/bin/env bash
set -euo pipefail

# Read-only health check for javaCardAuth (never calls gp.jar)

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

report() {
    local status="$1"
    local check="$2"
    local detail="$3"
    printf '[%-4s] %-28s %s\n' "$status" "$check" "$detail"
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    esac
}

MODE="generic"
if [[ -d "$HOME/myOs/dotfiles/gnupg" ]]; then
    MODE="myos"
elif [[ -L "$HOME/.gnupg/gpg-agent.conf" ]] && [[ "$(readlink -f "$HOME/.gnupg/gpg-agent.conf" 2>/dev/null || true)" == *"/myOs/"* ]]; then
    MODE="myos"
fi

SUDO_BIN="$(command -v sudo || true)"
SUDO_VARIANT="unknown"
if [[ -n "$SUDO_BIN" ]]; then
    if sudo --version 2>/dev/null | grep -qi 'sudo-rs'; then
        SUDO_VARIANT="sudo-rs"
    else
        SUDO_VARIANT="sudo"
    fi
fi
OS_ID="unknown"
if [[ -r /etc/os-release ]]; then
    OS_ID="$(
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${PRETTY_NAME:-${ID:-unknown}}"
    )"
fi
report PASS "environment" "os='$OS_ID' mode=$MODE sudo=$SUDO_VARIANT"

# 1. ~/.gnupg isolation & permissions
if [[ -L "$HOME/.gnupg" ]]; then
    report FAIL "gnupg_dir" "$HOME/.gnupg is a symlink (tree-folding risk)"
elif [[ ! -d "$HOME/.gnupg" ]]; then
    report FAIL "gnupg_dir" "$HOME/.gnupg directory missing"
else
    perms="$(stat -c '%a' "$HOME/.gnupg")"
    if [[ "$perms" == "700" ]]; then
        report PASS "gnupg_dir" "$HOME/.gnupg exists (mode 700, not symlink)"
    else
        report WARN "gnupg_dir" "$HOME/.gnupg mode is $perms (expected 700)"
    fi
fi

# 2. scdaemon & pcscd
if [[ -r "$HOME/.gnupg/scdaemon.conf" ]] && grep -q 'disable-ccid' "$HOME/.gnupg/scdaemon.conf"; then
    report PASS "scdaemon_conf" "disable-ccid enabled"
else
    report WARN "scdaemon_conf" "disable-ccid missing in ~/.gnupg/scdaemon.conf"
fi

if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet pcscd.socket 2>/dev/null || systemctl is-active --quiet pcscd.service 2>/dev/null; then
        report PASS "pcscd" "pcscd active"
    else
        report WARN "pcscd" "pcscd.socket/service not active"
    fi

    if systemctl --user is-active --quiet gcr-ssh-agent.socket 2>/dev/null; then
        report WARN "gcr_ssh_agent" "GNOME gcr-ssh-agent.socket active (may conflict with SSH_AUTH_SOCK)"
    else
        report PASS "gcr_ssh_agent" "no conflicting gcr-ssh-agent.socket"
    fi
else
    report WARN "systemd" "systemctl not available"
fi

# 3. SSH_AUTH_SOCK alignment
EXPECTED_SOCK="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)"
if [[ -n "$EXPECTED_SOCK" && "${SSH_AUTH_SOCK:-}" == "$EXPECTED_SOCK" && -S "$EXPECTED_SOCK" ]]; then
    report PASS "ssh_auth_sock" "matches $EXPECTED_SOCK"
elif [[ -n "$EXPECTED_SOCK" && -S "$EXPECTED_SOCK" ]]; then
    report WARN "ssh_auth_sock" "current='${SSH_AUTH_SOCK:-unset}' expected='$EXPECTED_SOCK'"
else
    report WARN "ssh_auth_sock" "gpg-agent SSH socket missing (${EXPECTED_SOCK:-unknown})"
fi

# 4. pinentry-labeled binary & backend check
PINENTRY_BIN="/usr/local/bin/pinentry-labeled"
if [[ -x "$PINENTRY_BIN" ]]; then
    if grep -q -- '--check-backend' "$PINENTRY_BIN" 2>/dev/null; then
        backend_out="$(timeout 3 "$PINENTRY_BIN" --check-backend < /dev/null 2>&1 || true)"
        if [[ -n "$backend_out" && -x "$backend_out" ]]; then
            report PASS "pinentry_labeled" "installed, backend=$backend_out"
        else
            report FAIL "pinentry_labeled" "backend resolution failed: ${backend_out:-none}"
        fi
    else
        report WARN "pinentry_labeled" "$PINENTRY_BIN lacks --check-backend (legacy version; run ./install.sh to upgrade)"
    fi
else
    report WARN "pinentry_labeled" "$PINENTRY_BIN not installed"
fi

# 5. Card status & SSH key (non-fatal if card unplugged)
if gpg --card-status >/dev/null 2>&1; then
    report PASS "javacard_status" "SmartPGP card detected by scdaemon"
else
    report WARN "javacard_status" "card not detected (unplugged or scdaemon busy)"
fi

if ssh_out="$(ssh-add -L 2>/dev/null)" && [[ -n "$ssh_out" ]]; then
    key_count="$(printf '%s\n' "$ssh_out" | wc -l)"
    report PASS "ssh_add" "$key_count SSH key(s) exposed via agent"
else
    report WARN "ssh_add" "no keys exposed by ssh-add -L"
fi

if [[ -r "$HOME/.gnupg/sshcontrol" ]] && grep -Eq '^[0-9A-Fa-f]{40}[[:space:]].*confirm' "$HOME/.gnupg/sshcontrol"; then
    report PASS "sshcontrol" "confirm flag enabled"
else
    report WARN "sshcontrol" "confirm flag not set in ~/.gnupg/sshcontrol"
fi

# 6. sudoers & PAM check
if [[ -e /etc/sudoers.d/ssh-agent ]]; then
    s_mode="$(stat -c '%a' /etc/sudoers.d/ssh-agent)"
    if [[ "$s_mode" == "440" || "$s_mode" == "400" ]]; then
        if (( EUID == 0 )) && ! visudo -cf /etc/sudoers.d/ssh-agent >/dev/null 2>&1; then
            report FAIL "sudoers_ssh_agent" "visudo syntax check failed"
        else
            report PASS "sudoers_ssh_agent" "/etc/sudoers.d/ssh-agent mode=$s_mode"
        fi
    else
        report FAIL "sudoers_ssh_agent" "unsafe mode $s_mode (expected 440)"
    fi
else
    report WARN "sudoers_ssh_agent" "/etc/sudoers.d/ssh-agent missing"
fi

if [[ -s /etc/security/authorized_keys ]]; then
    ak_lines="$(grep -cvE '^[[:space:]]*(#|$)' /etc/security/authorized_keys || true)"
    report PASS "authorized_keys" "/etc/security/authorized_keys has $ak_lines key(s)"
else
    report WARN "authorized_keys" "/etc/security/authorized_keys missing or empty"
fi

for pam_name in sudo sudo-i; do
    pam_path="/etc/pam.d/$pam_name"
    if [[ ! -f "$pam_path" ]]; then
        continue
    fi
    has_ssh=false
    has_common=false
    grep -q 'pam_ssh_agent_auth.so' "$pam_path" && has_ssh=true
    grep -Eq '^@include[[:space:]]+common-auth([[:space:]]|$)' "$pam_path" && has_common=true
    if $has_ssh && $has_common; then
        report PASS "pam_${pam_name}" "pam_ssh_agent_auth + common-auth fallback present"
    elif $has_ssh && ! $has_common; then
        report FAIL "pam_${pam_name}" "missing @include common-auth password fallback!"
    else
        report WARN "pam_${pam_name}" "pam_ssh_agent_auth.so not configured"
    fi
done

# 7. envHelpers & recipients
if [[ -r "$HOME/.config/javacard-auth/envHelpers.sh" ]] || [[ -r "$HOME/.config/myos/env-helpers.sh" ]]; then
    report PASS "env_helpers" "installed"
else
    report WARN "env_helpers" "not installed in ~/.config/{javacard-auth,myos}"
fi

if [[ -s "$HOME/.config/javacard-auth/gpg-recipients" ]] || [[ -s "$HOME/.config/myos/gpg-recipients" ]]; then
    report PASS "gpg_recipients" "recipients file configured"
else
    report WARN "gpg_recipients" "gpg-recipients file not configured"
fi

printf '\nSummary: PASS=%d WARN=%d FAIL=%d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
