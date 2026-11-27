#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() {
    printf '[PASS] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1" >&2
    exit 1
}

echo "=== [1/5] Syntax & Lint Checks ==="
sh -n "$REPO_DIR/shell/profile.sh" || fail "sh -n shell/profile.sh"
bash -n "$REPO_DIR/install.sh" "$REPO_DIR/doctor.sh" "$REPO_DIR/shell/envHelpers.sh" "$REPO_DIR/tests/runTests.sh" || fail "bash -n"
shellcheck -s sh "$REPO_DIR/shell/profile.sh" || fail "shellcheck -s sh shell/profile.sh"
shellcheck "$REPO_DIR/install.sh" "$REPO_DIR/doctor.sh" "$REPO_DIR/shell/envHelpers.sh" "$REPO_DIR/tests/runTests.sh" || fail "shellcheck bash scripts"
/usr/bin/python3 -B -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$REPO_DIR/bin/pinentry-labeled" "$TMP_ROOT/pinentry-labeled.pyc" || fail "py_compile bin/pinentry-labeled"
pass "syntax & lint"

echo "=== [2/5] pinentry-labeled Assuan & Backend Tests ==="
BACKEND_CHECK="$("$REPO_DIR/bin/pinentry-labeled" --check-backend)"
[[ -n "$BACKEND_CHECK" && -x "$BACKEND_CHECK" ]] || fail "pinentry-labeled --check-backend"
[[ "$(readlink -f "$BACKEND_CHECK")" != "$(readlink -f "$REPO_DIR/bin/pinentry-labeled")" ]] || fail "recursion check"

MOCK_PINENTRY="$TMP_ROOT/mock-pinentry"
cat > "$MOCK_PINENTRY" <<'EOF'
#!/bin/sh
printf 'OK Mock pinentry ready\n'
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$MOCK_ASSUAN_LOG"
    case "$line" in
        BYE*)
            printf 'OK closing\n'
            exit 0
            ;;
        *)
            printf 'OK\n'
            ;;
    esac
done
EOF
chmod +x "$MOCK_PINENTRY"

LABELS_CONF="$TMP_ROOT/labels.conf"
cat > "$LABELS_CONF" <<'EOF'
[labels]
card_serial = AABBCCDD
card_label = DemoCard
master_key_ids = 1122334455667788
fallback_key_ids = 9988776655443322
fallback_label = RecoveryKey
EOF

MOCK_ASSUAN_LOG="$TMP_ROOT/assuan.log"
export MOCK_ASSUAN_LOG

ASSUAN_OUT="$(
    JAVACARD_PINENTRY_BIN="$MOCK_PINENTRY" \
    JAVACARD_LABELS_CONF="$LABELS_CONF" \
    "$REPO_DIR/bin/pinentry-labeled" <<'EOF'
SETTITLE client-should-be-ignored
SETDESC Please%20confirm%20SSH%20access
SETDESC Enter%20Admin%20PIN
SETDESC Enter%20PIN%20for%20card%20AABBCCDD
SETDESC Passphrase%20for%201122334455667788
SETDESC Passphrase%20for%209988776655443322
SETDESC Generic%20symmetric%20key
BYE
EOF
)"
printf '%s\n' "$ASSUAN_OUT" | grep -q 'OK Mock pinentry ready' || fail "missing greeting"

grep -qx 'SETTITLE \[CONFIRM AUTH\] DemoCard AABBCCDD' "$MOCK_ASSUAN_LOG" || fail "confirm title mismatch"
grep -qx 'SETTITLE \[ADMIN PIN\] DemoCard AABBCCDD' "$MOCK_ASSUAN_LOG" || fail "admin pin title mismatch"
grep -qx 'SETTITLE \[USER PIN\] DemoCard AABBCCDD' "$MOCK_ASSUAN_LOG" || fail "user pin title mismatch"
grep -qx 'SETTITLE \[MASTER KEY\] 1122334455667788' "$MOCK_ASSUAN_LOG" || fail "master key title mismatch"
grep -qx 'SETTITLE \[FALLBACK KEY\] RecoveryKey' "$MOCK_ASSUAN_LOG" || fail "fallback key title mismatch"
grep -qx 'SETTITLE \[PASSPHRASE\]' "$MOCK_ASSUAN_LOG" || fail "default title mismatch"
if grep -q 'client-should-be-ignored' "$MOCK_ASSUAN_LOG"; then
    fail "client SETTITLE leaked through proxy"
fi

# Verify newline/control char injection neutralization & self-recursion rejection
/usr/bin/python3 -B - "$REPO_DIR/bin/pinentry-labeled" <<'PY' || fail "pinentry unit security checks"
import importlib.machinery
import importlib.util
import os
import sys

path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("pinentry_labeled", path)
spec = importlib.util.spec_from_loader("pinentry_labeled", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

cfg = {
    "card_serial": "12\nSETCMD evil",
    "card_label": "Card\r\nBYE",
    "master_key_ids": ["AAAA"],
    "fallback_key_ids": ["BBBB"],
    "fallback_label": "FB\nINJECT",
}
t = mod.classify_title("Please confirm", cfg)
assert "\n" not in t and "\r" not in t, f"Control chars remained in title: {t!r}"

os.environ["JAVACARD_PINENTRY_BIN"] = path
resolved = mod.resolve_backend({"backend": path})
assert os.path.realpath(resolved) != os.path.realpath(path), "Recursion guard failed"
PY
pass "pinentry-labeled Assuan & security checks"

echo "=== [3/5] envHelpers.sh Tests ==="
TEST_HOME="$TMP_ROOT/home"
MOCK_BIN="$TMP_ROOT/bin"
WORK_DIR="$TMP_ROOT/work"
mkdir -p "$TEST_HOME/.config/javacard-auth" "$TEST_HOME/.config/myos" "$MOCK_BIN" "$WORK_DIR"

cat > "$MOCK_BIN/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
src=""
mode=""
recips=()
while (( $# > 0 )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -r) recips+=("$2"); shift 2 ;;
        --encrypt) mode="encrypt"; shift ;;
        --decrypt) mode="decrypt"; shift ;;
        --yes|--armor|--quiet) shift ;;
        *) src="$1"; shift ;;
    esac
done
if [[ "${MOCK_GPG_FAIL:-0}" == "1" ]]; then
    exit 2
fi
if [[ "$mode" == "encrypt" ]]; then
    {
        printf '# recips=%s\n' "${recips[*]}"
        cat "$src"
    } > "$out"
elif [[ "$mode" == "decrypt" ]]; then
    grep -v '^# recips=' "$src"
fi
EOF
chmod +x "$MOCK_BIN/gpg"

printf 'KEY_MYOS\n' > "$TEST_HOME/.config/myos/gpg-recipients"
printf 'KEY_JCA\n' > "$TEST_HOME/.config/javacard-auth/gpg-recipients"
printf 'KEY_ENV\n' > "$TMP_ROOT/custom-recips"

cat > "$WORK_DIR/.env" <<'EOF'
# comment
PLAIN=hello=world
export SINGLE='s p a c e'
DOUBLE="quoted $(ok)"
EOF

(
    # shellcheck disable=SC2030
    export HOME="$TEST_HOME"
    # shellcheck disable=SC2030
    export PATH="$MOCK_BIN:$PATH"
    # shellcheck disable=SC1091
    . "$REPO_DIR/shell/envHelpers.sh"

    [[ "$(_javacard_resolve_recipients_file)" == "$TEST_HOME/.config/javacard-auth/gpg-recipients" ]] || exit 1
    # shellcheck disable=SC2030
    export JAVACARD_RECIPIENTS_FILE="$TMP_ROOT/custom-recips"
    [[ "$(_javacard_resolve_recipients_file)" == "$TMP_ROOT/custom-recips" ]] || exit 1
    unset JAVACARD_RECIPIENTS_FILE

    cd "$WORK_DIR"
    envlock .env .env.gpg 2>/dev/null
    [[ "$(stat -c '%a' .env.gpg)" == "600" ]] || exit 1
    grep -q '# recips=KEY_JCA' .env.gpg || exit 1

    # Verify failed gpg leaves no leftover tmp files
    if MOCK_GPG_FAIL=1 envlock .env "$WORK_DIR/fail.gpg" 2>/dev/null; then
        exit 1
    fi
    if compgen -G "$WORK_DIR/fail.gpg.tmp.*" > /dev/null; then
        exit 1
    fi

    # Verify envrun injects variables safely
    # shellcheck disable=SC2016
    out_vars="$(envrun bash -c 'printf "%s|%s|%s\n" "$PLAIN" "$SINGLE" "$DOUBLE"')"
    # shellcheck disable=SC2016
    [[ "$out_vars" == 'hello=world|s p a c e|quoted $(ok)' ]] || exit 1
) || fail "envHelpers happy path"

# Verify envrun rejects malformed / dangerous inputs
# shellcheck disable=SC2016
for bad_line in \
    'BAD$(whoami)=1' \
    "UNMATCHED='abc" \
    'UNMATCHED_D="abc' \
    'INJECT=$(id)' \
    'BACKTICK=`id`' \
    'NO_EQUALS_LINE'; do
    printf '%s\n' "$bad_line" > "$WORK_DIR/bad.env.gpg"
    if (
        # shellcheck disable=SC2031
        export HOME="$TEST_HOME"
        # shellcheck disable=SC2031
        export PATH="$MOCK_BIN:$PATH"
        export ENV_GPG_FILE="$WORK_DIR/bad.env.gpg"
        # shellcheck disable=SC1091
        . "$REPO_DIR/shell/envHelpers.sh"
        envrun true 2>/dev/null
    ); then
        fail "envrun failed to reject: $bad_line"
    fi
done
pass "envHelpers lock/view/run security checks"

echo "=== [4/5] install.sh Dry-Run & Symlink Guard Tests ==="
GENERIC_HOME="$TMP_ROOT/generic-home"
mkdir -p "$GENERIC_HOME"
HOME="$GENERIC_HOME" "$REPO_DIR/install.sh" --dry-run --mode generic --skip-packages >/dev/null || fail "install.sh dry-run generic"

SYMLINK_HOME="$TMP_ROOT/symlink-home"
mkdir -p "$SYMLINK_HOME"
ln -s /tmp/nonexistent-target "$SYMLINK_HOME/.profile"
if HOME="$SYMLINK_HOME" "$REPO_DIR/install.sh" --dry-run --mode generic --skip-packages >/dev/null 2>&1; then
    fail "install.sh generic mode failed to refuse symlinked .profile"
fi

"$REPO_DIR/install.sh" --dry-run --mode myos --skip-packages >/dev/null || fail "install.sh dry-run myos"
HOME="$GENERIC_HOME" "$REPO_DIR/install.sh" --uninstall --dry-run >/dev/null || fail "install.sh uninstall dry-run"
pass "install.sh dry-run modes & symlink guard"

echo "=== [5/5] Sensitive Data Leak Check ==="
# Note: keep only generic structural/placeholder patterns here (never hardcode personal IDs in git).
LEAK_RE='(/home/[a-zA-Z0-9._-]+|/run/media/|@proton\.me|@gmail\.com)'
if [[ -n "${JAVACARD_EXTRA_FORBIDDEN_RE:-}" ]]; then
    LEAK_RE="$LEAK_RE|$JAVACARD_EXTRA_FORBIDDEN_RE"
fi
if grep -rnE "$LEAK_RE" "$REPO_DIR" --exclude-dir=.git --exclude-dir=__pycache__ --exclude=runTests.sh; then
    fail "Sensitive path/identifier found in working tree!"
fi
pass "zero sensitive leaks in working tree"

echo "ALL TESTS PASSED"
