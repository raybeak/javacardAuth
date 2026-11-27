# POSIX /bin/sh profile snippet for javaCardAuth (safe for dash/sh/login managers)
if [ -t 0 ] && command -v tty >/dev/null 2>&1; then
    _javacard_tty="$(tty 2>/dev/null || true)"
    if [ -n "$_javacard_tty" ] && [ "$_javacard_tty" != "not a tty" ]; then
        GPG_TTY="$_javacard_tty"
        export GPG_TTY
    fi
    unset _javacard_tty
fi

if command -v gpgconf >/dev/null 2>&1; then
    _javacard_ssh_sock="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)"
    if [ -n "$_javacard_ssh_sock" ]; then
        SSH_AUTH_SOCK="$_javacard_ssh_sock"
        export SSH_AUTH_SOCK
    fi
    unset _javacard_ssh_sock
fi

if [ -n "${BASH_VERSION:-}" ]; then
    if [ -f "$HOME/.config/javacard-auth/envHelpers.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.config/javacard-auth/envHelpers.sh"
    elif [ -f "$HOME/.config/myos/env-helpers.sh" ]; then
        # shellcheck disable=SC1091
        . "$HOME/.config/myos/env-helpers.sh"
    fi
fi
