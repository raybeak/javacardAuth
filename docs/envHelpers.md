# `.env.gpg` Helpers (`envlock`, `envview`, `envrun`)

`shell/envHelpers.sh` provides three Bash commands for managing workspace `.env` secrets with GPG without leaving decrypted plaintext on disk.

---

## 1. Command Reference

### `envlock [src] [dst]`
Encrypts a plaintext `.env` file into an ASCII-armored `.env.gpg` file for all listed OpenPGP recipients.

- **Arguments**:
  - `src` *(optional)*: Source plaintext file. Defaults to `./.env`, then `~/workspace/.env`, then `~/.env`.
  - `dst` *(optional)*: Output encrypted file. Defaults to `${src}.gpg`.
- **Recipient Resolution Order**:
  1. `$JAVACARD_RECIPIENTS_FILE` (if set)
  2. `~/.config/javacard-auth/gpg-recipients`
  3. `~/.config/myos/gpg-recipients`
  *(Blank lines and `#` comments are ignored; every remaining Key ID / Fingerprint is passed as `-r <id>`.)*
- **Safety Behavior**:
  - Writes to a `mktemp` staging file under `umask 077` first, checks `gpg` exit status, deletes the temp file on failure, sets `chmod 600`, and atomically `mv -f`s into `dst`.
  - Prints a reminder to destroy the plaintext source (`shred -u '<src>'`).
- **Examples**:
  ```bash
  envlock                         # ./.env -> ./.env.gpg
  envlock .env.prod .env.prod.gpg # custom input/output paths
  ```

---

### `envview [src]`
Decrypts an encrypted `.env.gpg` file directly to `stdout` without creating any file on disk.

- **Arguments**:
  - `src` *(optional)*: Encrypted `.env.gpg` path. If omitted, uses the resolution order below.
- **Safety Behavior**:
  - Calls `gpg --quiet --decrypt "$src"` and writes only to standard output.
- **Examples**:
  ```bash
  envview                         # print resolved .env.gpg to terminal
  envview ~/workspace/.env.gpg    # print explicit file
  ```

---

### `envrun <command> [args...]`
Decrypts `.env.gpg` into memory inside a subshell, parses `KEY=VAL` assignments safely, exports them **only to the child process**, and executes `<command> [args...]` via `exec`.

- **Arguments**:
  - `<command> [args...]` *(required)*: Command to execute with decrypted environment variables injected.
- **Supported `.env` Syntax**:
  - Blank lines and `#` comments are skipped.
  - Optional `export ` prefix (`export API_KEY=value`).
  - Matching single quotes (`KEY='value with spaces'`) or double quotes (`KEY="value"`).
  - Unquoted values (`KEY=hello=world`) as long as they do not contain unquoted `$(...)` or backticks.
- **Security Guarantees (No `eval` / No `source <(...)`)**:
  - Never invokes `eval` or process substitution `source <(...)`.
  - Validates variable names against `^[A-Za-z_][A-Za-z0-9_]*$`.
  - Rejects malformed lines without `=`, unmatched single/double quotes, and unquoted command substitutions (`$(...)` or `` `...` ``).
  - Cleans up internal parser variables before calling `exec "$@"`, so decrypted secrets exist only in the child process's RAM.
- **Examples**:
  ```bash
  envrun env
  ENV_GPG_FILE=.env.prod.gpg envrun ./deploy.sh
  ```

---

## 2. Encrypted File Resolution Order (`envview` & `envrun`)

When no explicit path is passed (or for `envrun` via `ENV_GPG_FILE`):

1. `$ENV_GPG_FILE` (if set)
2. `./.env.gpg`
3. `$HOME/workspace/.env.gpg`
4. `$HOME/.env.gpg`

---

## 3. Recommended Daily Workflow

```bash
cp .env.example .env            # 1. Fill in secrets temporarily
envlock                         # 2. Encrypt to .env.gpg (0600)
shred -u .env                   # 3. Destroy plaintext file
envview                         # 4. Inspect decrypted output in stdout
envrun python3 app.py           # 5. Run app with RAM-only env injection
```
