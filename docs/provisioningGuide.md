# SmartPGP JavaCard Provisioning Guide (Generic)

Use this guide when initializing a new JavaCard (`JavaCard 3.0.4+` with ECC support, e.g., `JCOP3`) or migrating an existing SmartPGP card onto a fresh Ubuntu machine.

---

## 1. Verify Existing Applets Safely (1 Attempt Only)

Never run GlobalPlatform (`gp.jar`) authentication commands inside retry loops: 3 consecutive authentication failures lock the Issuer Security Domain (`ISD`).

```bash
gpgconf --kill scdaemon
java -jar /path/to/gp.jar -l
```

If SmartPGP (`D27600012401...`) is already listed as `SELECTABLE`, skip Section 2.

---

## 2. Install `SmartPGPApplet.cap` (New Cards Only)

Verify the downloaded `.cap` archive checksum against upstream before loading, then install non-destructively (do **not** delete pre-existing applets such as `SeedKeeper`):

```bash
java -jar /path/to/gp.jar --install SmartPGPApplet.cap \
  --create D276000124010304AFAF<8_HEX_SERIAL>0000
gpgconf --kill scdaemon
gpg --card-status
```

Immediately change default User PIN (`123456`) and Admin PIN (`12345678`) via:

```bash
gpg --card-edit
# Inside gpg> prompt: admin -> passwd -> change PIN (1) and Admin PIN (3)
```

---

## 3. Generate `nistp256` Keys, Offline Encrypted Backup, and `keytocard`

1. Generate an ECC `nistp256` primary key (`Sign/Certify`) plus 3 subkeys (`Sign`, `Encrypt`, `Authenticate`) with `gpg --expert --full-generate-key` or `gpg --quick-gen-key` + `gpg --quick-add-key`.
2. Generate a revocation certificate (`gpg --gen-revoke <KEY_FPR> > revocation.asc`).
3. **Before** running `keytocard`, export the full secret key + revocation certificate to an offline USB drive encrypted with a strong symmetric passphrase:
   ```bash
   gpg --export-secret-keys --armor <KEY_FPR> | gpg -c -o /mnt/usb-backup/gpg-master-backup.asc.gpg
   gpg --export --armor <KEY_FPR> > /mnt/usb-backup/gpg-public.asc
   test -s /mnt/usb-backup/gpg-master-backup.asc.gpg
   ```
4. Move the 3 subkeys onto the card (`gpg --edit-key <KEY_FPR>` -> `toggle` -> select each subkey -> `keytocard` -> `save`).
5. Verify the offline backup decrypts cleanly, then delete the local master private key so NVMe retains only card stubs (`sec#`, `ssb>`):
   ```bash
   gpg --delete-secret-keys <KEY_FPR>
   gpg --card-status
   ```

---

## 4. Configure Host PnP Files

1. Populate `~/.config/javacard-auth/labels.conf` with your card's serial (`gpg --card-status | grep Serial`), master key ID, and optional local fallback key ID.
2. Populate `~/.config/javacard-auth/gpg-recipients` with your card key fingerprint (plus optional local fallback key fingerprint for dual-recipient `.env.gpg` recovery).
3. Enable `confirm` in `~/.gnupg/sshcontrol` and register your card SSH key for `sudo`:
   ```bash
   ./install.sh --enable-confirm --export-auth-key --skip-packages
   ```
   Test password fallback immediately:
   ```bash
   SSH_AUTH_SOCK="" sudo -k true
   ```
4. Configure Git commit signing:
   ```bash
   git config --global user.signingkey <YOUR_SIGNING_FPR>
   git config --global commit.gpgsign true
   ```
