# javaCardAuth

**Language**: English | [한국어 (README.ko.md)](README.ko.md)

Plug-and-Play OpenPGP Smartcard (`SmartPGP` / JavaCard) integration for **Ubuntu-based Linux distributions** (`22.04`, `24.04`, `26.04`, Pop!_OS, Linux Mint) and **`myOs`** (`Stow` + Sway).

---

## 1. Concept & Architecture

`javaCardAuth` turns a JavaCard running `SmartPGP` (optionally coexisting with applets like `SeedKeeper`) into a single hardware root of trust for **SSH authentication, Git commit signing, `sudo` / `sudo-i` privilege escalation, and `.env.gpg` secret management** — while preserving a **100% password/key fallback** whenever the card is unplugged.

### Core Design Principles
- **Single CCID Owner (`pcscd` -> `scdaemon` -> `gpg-agent`)**: `scdaemon.conf` enables `disable-ccid` so `scdaemon` accesses the reader exclusively through `pcscd` instead of fighting over raw `libusb`.
- **Offline Master Key (`sec#`) & Card Stubs (`ssb>`)**: The OpenPGP primary key stays offline in an encrypted backup; only the `Sign`, `Encrypt`, and `Auth` subkeys live on the JavaCard.
- **Per-Request `sudo` Confirmation (`sshcontrol` `confirm`)**: `gpg-agent` exposes the card `Auth` key over `SSH_AUTH_SOCK`, and `sshcontrol`'s `confirm` flag forces an explicit pinentry confirmation dialog on every `sudo` / SSH request so a cached User PIN never grants silent root access.
- **Password Fallback Invariant (`@include common-auth`)**: `pam_ssh_agent_auth.so` is inserted as `sufficient` strictly above `@include common-auth` in `/etc/pam.d/sudo` and `/etc/pam.d/sudo-i`. Unplugging the card or clearing `SSH_AUTH_SOCK` immediately falls back to your normal Linux password.
- **Context-Labeled Pinentry (`pinentry-labeled`)**: An Assuan proxy intercepts `SETDESC`, decodes percent-encoded text, sanitizes control characters, auto-selects `pinentry-qt`, `pinentry-gnome3`, or `pinentry-curses`/`pinentry-tty`, and displays clear window titles (`[CONFIRM AUTH]`, `[USER PIN]`, `[ADMIN PIN]`, `[MASTER KEY]`, `[FALLBACK KEY]`).
- **Zero-Plaintext `.env.gpg` Workflow**: `envlock` encrypts `.env` atomically (`0600`) to multiple recipients (card key + optional offline/software fallback key); `envview` decrypts to stdout; `envrun` parses `KEY=VAL` in pure Bash without `eval` or `source <(...)` and injects variables only into the child process's memory.

```text
JavaCard (SmartPGP) -> pcscd.socket -> scdaemon (disable-ccid) -> gpg-agent (SSH_AUTH_SOCK)
  ├── SSH & Git Commit Signing (-S)
  ├── sudo / sudo-i (pam_ssh_agent_auth [sufficient] -> fallback @include common-auth)
  ├── pinentry-labeled (Assuan Proxy -> qt / gnome3 / curses)
  └── envlock / envview / envrun (.env.gpg RAM-only execution)
```

For full Mermaid diagrams and sequence flows, see [docs/howItWorks.md](docs/howItWorks.md).

---

## 2. Supported Environments

- **myOs / Ubuntu 26.04 (Verified Host)**: Auto-detected (`--mode myos`). Preserves existing `stow --no-folding` symlinks (`~/.gnupg/{gpg-agent.conf,scdaemon.conf}`, `~/.profile`, `~/.config/myos/env-helpers.sh`) while installing `/usr/local/bin/pinentry-labeled`, templates, and `doctor.sh` checks.
- **Generic Ubuntu Desktop / Server (22.04 / 24.04 / 26.04+)**: Designed around standard Debian/Ubuntu APT packages (`gnupg`, `scdaemon`, `pcscd`, `libccid`, `opensc`, `libpam-ssh-agent-auth`) and `@include common-auth` PAM conventions, real `0700` `~/.gnupg` setup (no symlink tree-folding), POSIX `~/.profile`, and optional `gcr-ssh-agent` masking on GNOME.

---

## 3. How to Use

### Step 1: Preview with Dry-Run

```bash
./install.sh --dry-run
```

### Step 2: Run Installer

Generic Ubuntu (auto-detects desktop/TTY and mode):

```bash
./install.sh --with-nvim
```

Ubuntu Desktop running GNOME (prevents `gcr-ssh-agent` from overriding `SSH_AUTH_SOCK`):

```bash
./install.sh --disable-gcr-ssh-agent --with-nvim
```

On `myOs` (`~/myOs/dotfiles/gnupg` auto-detected):

```bash
./install.sh --mode myos --skip-pam
```

### Step 3: Provision Card & Configure Personal IDs

If you are initializing a brand-new JavaCard, follow [docs/provisioningGuide.md](docs/provisioningGuide.md) first. Otherwise, import your public key (`gpg --import public.asc && gpg --card-status`) and configure:

1. `~/.config/javacard-auth/labels.conf` (copied from [config/labels.conf.example](config/labels.conf.example)): set `card_serial`, `master_key_ids`, and optional `fallback_key_ids`.
2. `~/.config/javacard-auth/gpg-recipients` (copied from [config/gpg-recipients.example](config/gpg-recipients.example)): list one OpenPGP key fingerprint/ID per line for `envlock`.
3. Enforce `confirm` on your card `Auth` keygrip:
   ```bash
   ./install.sh --enable-confirm --skip-packages --skip-pam
   ```

### Step 4: Enable `sudo` / `sudo-i` Card Auth (Optional)

Before modifying PAM, **open a separate root shell (`sudo -i`) and keep it open** until fallback testing passes:

```bash
ssh-add -L > /tmp/card-auth.pub
./install.sh --auth-key-file /tmp/card-auth.pub --skip-packages
rm -f /tmp/card-auth.pub
```

Verify password fallback immediately (with card unplugged or `SSH_AUTH_SOCK` cleared):

```bash
SSH_AUTH_SOCK="" sudo -k true
```

### Step 5: Verify Setup (`doctor.sh`)

```bash
./doctor.sh
```

---

## 4. Daily Commands

- **SSH**: `ssh -T git@github.com`
- **Git Commit Signing**:
  ```bash
  git config --global user.signingkey <YOUR_SIGNING_FPR>
  git config --global commit.gpgsign true
  git commit -S -m "feat: signed commit"
  ```
- **Workspace `.env.gpg`** (full command reference in [docs/envHelpers.md](docs/envHelpers.md)):
  ```bash
  cp .env.example .env          # add secrets, then encrypt:
  envlock                       # creates .env.gpg (0600)
  shred -u .env                 # destroy plaintext on disk
  envview                       # print decrypted vars to stdout
  envrun <command> [args...]    # inject vars into child process RAM only
  ```
  Override file locations with `ENV_GPG_FILE` and `JAVACARD_RECIPIENTS_FILE` when needed.

---

## 5. Safety, Troubleshooting & Uninstall

- **`SCARD_E_SHARING_VIOLATION` when running `gp.jar` / `opensc`**: `scdaemon` holds exclusive reader ownership. Run `gpgconf --kill scdaemon` before direct smartcard management.
- **GlobalPlatform (`gp.jar`) Lockout Prevention**: Never retry failing `gp.jar` authentication commands automatically; 3 consecutive failures permanently lock the card's `ISD`.
- **Admin PIN Lockout**: 3 consecutive wrong Admin PIN entries lock OpenPGP admin operations until factory reset.
- **Uninstall / Partial Revert**:
  ```bash
  ./install.sh --uninstall
  ```
  - **Removes**: `# >>> javaCardAuth >>>` blocks in `~/.profile` / `~/.bashrc` and `/etc/pam.d/sudo*`, `/usr/local/bin/pinentry-labeled`, `/etc/sudoers.d/ssh-agent`, `~/.config/nvim/plugin/nvimGpgGuard.lua`, and restores `gcr-ssh-agent.socket` if it was active before install.
  - **Preserves**: `~/.gnupg` keys/configs, `/etc/security/authorized_keys`, `~/.config/javacard-auth/{labels.conf,gpg-recipients}`, and PAM backups in `/var/backups/javacard-auth/`.

---

## 6. Repository Layout

- [install.sh](install.sh): Idempotent PnP installer and uninstaller (`--dry-run`, `--mode auto|myos|generic`, `--user`, `--uninstall`)
- [doctor.sh](doctor.sh): Read-only diagnostic checker (never runs `gp.jar`)
- [bin/pinentry-labeled](bin/pinentry-labeled): Assuan proxy with desktop/TTY pinentry auto-detection and configurable title labeling
- [shell/profile.sh](shell/profile.sh): Strict POSIX `/bin/sh` environment setup (`GPG_TTY`, `SSH_AUTH_SOCK`, Bash helper loader)
- [shell/envHelpers.sh](shell/envHelpers.sh): `envlock`, `envview`, `envrun`
- `config/`: Templates for `gnupg`, `sudoers.d/ssh-agent`, `labels.conf.example`, `gpg-recipients.example`
- [nvimGpgGuard.lua](nvimGpgGuard.lua): Neovim leak guard for `*.gpg` / `*.asc` buffers
- [docs/howItWorks.md](docs/howItWorks.md): Architecture and sequence diagrams
- [docs/provisioningGuide.md](docs/provisioningGuide.md): Clean-room SmartPGP applet & `nistp256` key provisioning guide
- [docs/envHelpers.md](docs/envHelpers.md): Command reference for `envlock`, `envview`, and `envrun`
- [tests/runTests.sh](tests/runTests.sh): Offline lint, Assuan mock, `envrun` parser, and dry-run test suite
