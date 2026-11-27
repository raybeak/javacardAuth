# How It Works: SmartPGP JavaCard + `sudo` / `sudo-rs` Auth

## 1. System Architecture Overview

One JavaCard running `SmartPGP` (optionally coexisting with applets such as `SeedKeeper`) handles OpenPGP Sign, Encrypt, and Auth subkeys. On the Linux host, **`pcscd` -> `scdaemon` -> `gpg-agent`** serializes all card operations through a single owner to prevent CCID reader contention.

```mermaid
flowchart TD
    CARD["JavaCard (USB-C / Internal CCID Reader)"]
    PGP["SmartPGP Applet (nistp256: Sign / Encrypt / Auth)"]
    PCSCD["pcscd.socket (CCID Multiplexer)"]
    SCD["scdaemon (disable-ccid, Sole Owner)"]
    AGENT["gpg-agent (enable-ssh-support + sshcontrol confirm)"]
    PIN["pinentry-labeled (Assuan Proxy -> qt / gnome3 / curses)"]

    SUDO["sudo / sudo-i (sudo or sudo-rs + pam_ssh_agent_auth)"]
    SSH["SSH & Git Commit Signing (-S)"]
    ENV["Workspace .env.gpg (envlock / envview / envrun)"]
    FB["Fallback: Linux Password / Local Backup Key"]

    CARD --> PGP --> PCSCD --> SCD --> AGENT
    AGENT <--> PIN
    AGENT -->|"SSH_AUTH_SOCK"| SUDO
    AGENT -->|"SSH_AUTH_SOCK + Sign"| SSH
    AGENT -->|"Unwrap Session Key"| ENV
    FB -.->|"Card Unplugged"| SUDO
    FB -.->|"Card Unplugged"| ENV
```

---

## 2. End-to-End Authentication & Encryption Workflows

```mermaid
sequenceDiagram
    participant U as User Shell
    participant S as sudo / sudo-rs / PAM
    participant G as gpg-agent (SSH_AUTH_SOCK)
    participant P as pinentry-labeled
    participant D as scdaemon -> pcscd
    participant C as JavaCard (SmartPGP)

    Note over U,C: 1. sudo / sudo-i Authentication
    U->>S: sudo -k true
    S->>G: pam_ssh_agent_auth (/etc/security/authorized_keys)
    G->>P: SETDESC (confirm prompt via sshcontrol)
    P-->>G: User approves OK
    G->>D: Request AUTH slot signature
    D->>C: APDU Sign (Auth Slot)
    alt Card Inserted + Valid PIN + Confirmed
        C-->>D: Signature OK
        D-->>G: Signature OK
        G-->>S: Auth Success (sufficient -> skip password)
    else Card Missing, Canceled, or Auth Fails
        S->>U: Fallback to @include common-auth (Linux Password)
    end

    Note over U,C: 2. Workspace .env Hybrid Encryption (envlock / envrun)
    U->>G: envlock (.env -> .env.gpg)
    G-->>U: Random AES-256 session key wrapped for listed recipients
    U->>G: envrun cmd (decrypt + validate KEY=VAL in memory subshell)
    G->>C: Unwrap AES-256 session key (Encrypt Slot + User PIN)
    C-->>G: Session Key
    G-->>U: exec cmd with RAM-only env vars (0 plaintext written to disk)
```

---

## 3. Core Security Boundaries

- **Single Reader Owner (`disable-ccid`)**: `scdaemon.conf` delegates USB CCID transport to `pcscd`, preventing libusb contention. Release `scdaemon` via `gpgconf --kill scdaemon` before using GlobalPlatform (`gp.jar`) directly.
- **No-Folding `~/.gnupg` Isolation**: `~/.gnupg` stays a real `0700` directory; only config files (`gpg-agent.conf`, `scdaemon.conf`) are managed, so private stubs and trust databases never enter Git repositories.
- **Per-Request Confirmation (`sshcontrol` `confirm`)**: Adding `confirm` after the AUTH keygrip prevents silent root `sudo` reuse while `gpg-agent` caches the User PIN.
- **Labeled Assuan Pinentry Proxy (`pinentry-labeled`)**: Decodes percent-encoded `SETDESC` strings, sanitizes control characters, injects context-specific `SETTITLE` headers, and selects `pinentry-qt`, `pinentry-gnome3`, or `pinentry-curses` automatically while guarding against self-recursion.
- **Dual PAM + Password Fallback**: Both `/etc/pam.d/sudo` and `/etc/pam.d/sudo-i` receive `auth sufficient pam_ssh_agent_auth.so file=/etc/security/authorized_keys` strictly above `@include common-auth`. `/etc/sudoers.d/ssh-agent` preserves `SSH_AUTH_SOCK` and is syntax-checked with `visudo -cf`.
- **Non-Executing `.env` Loader**: `envrun` never runs `eval` or `source <(...)`; it parses `KEY=VAL` assignments in bash parameter expansion, rejects unquoted command substitutions and invalid variable names, and passes variables exclusively to the child process.
