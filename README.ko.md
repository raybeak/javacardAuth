# javaCardAuth

**Language**: [English (README.md)](README.md) | 한국어

**Ubuntu 기반 Linux 배포판**(`22.04`, `24.04`, `26.04`, Pop!_OS, Linux Mint)과 **`myOs`**(`Stow` + Sway)에서 바로 쓸 수 있는 Plug-and-Play OpenPGP Smartcard(`SmartPGP` / JavaCard) 통합 도구입니다.

---

## 1. 개념 및 아키텍처

`javaCardAuth`는 `SmartPGP`가 탑재된 JavaCard 한 장(`SeedKeeper` 등 기존 Applet과 공존 가능)으로 **SSH 인증, Git 커밋 서명, `sudo` / `sudo-i` 권한 상승, `.env.gpg` 비밀변수 관리**를 일원화하며, 카드가 분리된 상황에서도 **100% Password / Backup Key Fallback**을 보장합니다.

### 핵심 설계 원칙
- **단일 CCID 점유 (`pcscd` -> `scdaemon` -> `gpg-agent`)**: `scdaemon.conf`에 `disable-ccid`를 적용해 `scdaemon`이 raw `libusb` 경합 없이 `pcscd`를 통해서만 리더기를 점유합니다.
- **오프라인 Master Key (`sec#`) 및 카드 Stub (`ssb>`)**: OpenPGP Primary Key는 암호화된 오프라인 백업으로 분리 보관하고, 카드에는 `Sign`, `Encrypt`, `Auth` Subkey 3개만 남깁니다.
- **요청별 `sudo` 확인 (`sshcontrol` `confirm`)**: `gpg-agent`가 `SSH_AUTH_SOCK`으로 카드 `Auth` 키를 노출하고, `sshcontrol`의 `confirm` 플래그로 매 `sudo`·SSH 요청마다 pinentry 확인 창을 띄워 캐시된 User PIN만으로 무음 `root` 상승이 일어나는 것을 막습니다.
- **Password Fallback 불변식 (`@include common-auth`)**: `/etc/pam.d/sudo`와 `/etc/pam.d/sudo-i`의 `@include common-auth` 바로 위에 `pam_ssh_agent_auth.so`를 `sufficient`로 삽입합니다. 카드를 빼거나 `SSH_AUTH_SOCK`을 비우면 즉시 일반 Linux 비밀번호 프롬프트로 전환됩니다.
- **문맥 라벨링 Pinentry (`pinentry-labeled`)**: Assuan proxy가 `SETDESC`의 percent-encoding을 디코딩하고 제어문자를 제거한 뒤, 환경에 맞는 `pinentry-qt`, `pinentry-gnome3`, `pinentry-curses`/`pinentry-tty`를 자동 선택해 `[CONFIRM AUTH]`, `[USER PIN]`, `[ADMIN PIN]`, `[MASTER KEY]`, `[FALLBACK KEY]` 창 제목을 표시합니다.
- **무평문 `.env.gpg` 워크플로우**: `envlock`은 `.env`를 다중 수신자(카드 키 + 선택적 오프라인/소프트웨어 백업 키)로 원자적 암호화(`0600`)하고, `envview`는 stdout 출력만 수행하며, `envrun`은 `eval`·`source <(...)` 없이 순수 Bash 파서로 `KEY=VAL`을 검증한 뒤 자식 프로세스 메모리에만 주입합니다.

```text
JavaCard (SmartPGP) -> pcscd.socket -> scdaemon (disable-ccid) -> gpg-agent (SSH_AUTH_SOCK)
  ├── SSH & Git Commit Signing (-S)
  ├── sudo / sudo-i (pam_ssh_agent_auth [sufficient] -> fallback @include common-auth)
  ├── pinentry-labeled (Assuan Proxy -> qt / gnome3 / curses)
  └── envlock / envview / envrun (.env.gpg RAM-only 실행)
```

전체 Mermaid 아키텍처 및 시퀀스 다이어그램은 [docs/howItWorks.md](docs/howItWorks.md)를 참고하세요.

---

## 2. 지원 환경

- **myOs / Ubuntu 26.04 (실측 검증)**: 자동 감지(`--mode myos`). 기존 `stow --no-folding` 심볼릭 링크(`~/.gnupg/{gpg-agent.conf,scdaemon.conf}`, `~/.profile`, `~/.config/myos/env-helpers.sh`)를 보존한 채 `/usr/local/bin/pinentry-labeled`, 템플릿, `doctor.sh` 진단을 제공합니다.
- **범용 Ubuntu Desktop / Server (22.04 / 24.04 / 26.04+)**: 표준 Debian/Ubuntu APT 패키지(`gnupg`, `scdaemon`, `pcscd`, `libccid`, `opensc`, `libpam-ssh-agent-auth`) 및 `@include common-auth` PAM 규칙을 기반으로 동작하며, `~/.gnupg` 실제 디렉터리(`0700`) 유지, POSIX `~/.profile` 연동, GNOME `gcr-ssh-agent` 비활성화 옵션을 지원합니다.

---

## 3. 사용 방법

### 1단계: Dry-Run으로 사전 확인

```bash
./install.sh --dry-run
```

### 2단계: 설치 실행

범용 Ubuntu (데스크톱/TTY 및 모드 자동 감지):

```bash
./install.sh --with-nvim
```

GNOME 기반 Ubuntu Desktop (`gcr-ssh-agent`가 `SSH_AUTH_SOCK`을 가로채는 문제 방지):

```bash
./install.sh --disable-gcr-ssh-agent --with-nvim
```

`myOs` 환경 (`~/myOs/dotfiles/gnupg` 자동 감지):

```bash
./install.sh --mode myos --skip-pam
```

### 3단계: 카드 프로비저닝 및 개인 식별자 설정

신규 JavaCard를 처음 초기화하는 경우 먼저 [docs/provisioningGuide.md](docs/provisioningGuide.md)를 따라 주세요. 이미 키가 탑재된 카드라면 공개키를 가져온 뒤(`gpg --import public.asc && gpg --card-status`) 아래 두 파일을 설정합니다:

1. `~/.config/javacard-auth/labels.conf` ([config/labels.conf.example](config/labels.conf.example)에서 복사): `card_serial`, `master_key_ids`, 선택적 `fallback_key_ids` 입력
2. `~/.config/javacard-auth/gpg-recipients` ([config/gpg-recipients.example](config/gpg-recipients.example)에서 복사): `envlock` 수신자 OpenPGP fingerprint/ID를 한 줄에 하나씩 입력
3. 카드 `Auth` keygrip에 `confirm` 강제:
   ```bash
   ./install.sh --enable-confirm --skip-packages --skip-pam
   ```

### 4단계: `sudo` / `sudo-i` 카드 인증 활성화 (선택)

PAM을 수정하기 전에 **반드시 별도 root 셸(`sudo -i`)을 열어 둔 상태**에서 진행하고 fallback 검증 전까지 닫지 마세요:

```bash
ssh-add -L > /tmp/card-auth.pub
./install.sh --auth-key-file /tmp/card-auth.pub --skip-packages
rm -f /tmp/card-auth.pub
```

적용 직후 카드 분리(또는 `SSH_AUTH_SOCK` 해제) 상태에서 비밀번호 fallback을 검증합니다:

```bash
SSH_AUTH_SOCK="" sudo -k true
```

### 5단계: 상태 진단 (`doctor.sh`)

```bash
./doctor.sh
```

---

## 4. 일상 사용 명령어

- **SSH**: `ssh -T git@github.com`
- **Git 커밋 서명**:
  ```bash
  git config --global user.signingkey <YOUR_SIGNING_FPR>
  git config --global commit.gpgsign true
  git commit -S -m "feat: signed commit"
  ```
- **Workspace `.env.gpg`** (상세 명령어 레퍼런스: [docs/envHelpers.md](docs/envHelpers.md)):
  ```bash
  cp .env.example .env          # 비밀값 작성 후 암호화:
  envlock                       # .env.gpg (0600) 생성
  shred -u .env                 # 디스크 평문 파기
  envview                       # stdout으로 복호화 내용 확인
  envrun <command> [args...]    # 자식 프로세스 RAM에만 주입해 실행
  ```
  필요 시 `ENV_GPG_FILE`, `JAVACARD_RECIPIENTS_FILE` 환경변수로 경로를 재정의할 수 있습니다.

---

## 5. 안전 수칙, 문제 해결 및 제거

- **`gp.jar` / `opensc` 실행 시 `SCARD_E_SHARING_VIOLATION` 발생**: `scdaemon`이 리더기를 단독 점유 중입니다. `gpgconf --kill scdaemon`으로 락을 해제한 뒤 실행하세요.
- **GlobalPlatform (`gp.jar`) 잠금 주의**: 인증이 실패하는 `gp.jar` 명령을 자동으로 재시도하지 마세요. 연속 3회 실패 시 카드의 `ISD`가 영구 잠금됩니다.
- **Admin PIN 잠금 주의**: Admin PIN 연속 3회 오입력 시 초기화 전까지 OpenPGP 관리자 기능이 잠깁니다.
- **제거 / 부분 롤백 (`--uninstall`)**:
  ```bash
  ./install.sh --uninstall
  ```
  - **제거 항목**: `~/.profile` / `~/.bashrc` 및 `/etc/pam.d/sudo*`의 `# >>> javaCardAuth >>>` 마커 블록, `/usr/local/bin/pinentry-labeled`, `/etc/sudoers.d/ssh-agent`, `~/.config/nvim/plugin/nvimGpgGuard.lua` 제거 및 설치 전 활성 상태였던 `gcr-ssh-agent.socket` 복원
  - **보존 항목**: `~/.gnupg` 키·설정, `/etc/security/authorized_keys`, `~/.config/javacard-auth/{labels.conf,gpg-recipients}`, `/var/backups/javacard-auth/` 내 PAM 백업

---

## 6. 저장소 구조

- [install.sh](install.sh): 멱등성 보장 PnP 설치/제거 스크립트 (`--dry-run`, `--mode auto|myos|generic`, `--user`, `--uninstall`)
- [doctor.sh](doctor.sh): Read-only 진단 스크립트 (`gp.jar` 미호출)
- [bin/pinentry-labeled](bin/pinentry-labeled): 데스크톱/TTY 자동 감지 및 창 제목 라벨링 Assuan proxy
- [shell/profile.sh](shell/profile.sh): Strict POSIX `/bin/sh` 환경 초기화 (`GPG_TTY`, `SSH_AUTH_SOCK`, Bash 헬퍼 로더)
- [shell/envHelpers.sh](shell/envHelpers.sh): `envlock`, `envview`, `envrun`
- `config/`: `gnupg`, `sudoers.d/ssh-agent`, `labels.conf.example`, `gpg-recipients.example` 템플릿
- [nvimGpgGuard.lua](nvimGpgGuard.lua): Neovim `*.gpg` / `*.asc` 버퍼 평문 유출 차단 설정
- [docs/howItWorks.md](docs/howItWorks.md): 아키텍처 및 시퀀스 다이어그램
- [docs/provisioningGuide.md](docs/provisioningGuide.md): 클린룸 SmartPGP Applet 및 `nistp256` 키 프로비저닝 가이드
- [docs/envHelpers.md](docs/envHelpers.md): `envlock`, `envview`, `envrun` 명령어 상세 레퍼런스
- [tests/runTests.sh](tests/runTests.sh): 오프라인 lint, mock Assuan, `envrun` 파서, dry-run 테스트 스위트
