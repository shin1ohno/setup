# GPG Secret-Subkey Distribution to Headless Hosts

Load when provisioning a GPG signing (or auth) subkey onto an unattended host — cloud VM, CI runner, cookbook-managed LXC — via a secret store (GCP Secret Manager, AWS SSM, Vault) rather than a manual `gpg --import` at a keyboard.

The whole difficulty is that a headless host has no reachable pinentry, so the key must arrive **unprotected**, and every step that can silently fail to strip the protection does so without an error.

## Export preserves passphrase protection — the target host cannot use it

`gpg --export-secret-subkeys 'KEYID!'` exports the subkey **with its existing passphrase protection intact** (the trailing `!` pins that one subkey so the primary never travels). Piped straight into a secret store, the host imports it fine and then dies at first use:

```
gpg: signing failed: Inappropriate ioctl for device
```

which git reports as `fatal: failed to write commit object` — indistinguishable from a missing key.

## `--batch` export silently DROPS a protected subkey

Exporting with `--batch` and no `--pinentry-mode loopback --passphrase …` does not fail. It omits the protected secret-key packet and writes a **primary-stub-only blob** that is non-empty, exits 0, imports with `secret key imported`, and then reports `No secret key` for the subkey. Each attempt burns one secret-store version with nothing to diagnose. The tell is in the packets, so check them before uploading:

```bash
gpg --list-packets <blob> | grep -c 'secret sub key'   # want 1, not 0
gpg --list-packets <blob> | grep -ci s2k               # want 0 (0 = unprotected)
```

## `gpg --passwd <keyid>` cannot strip a subkey passphrase when the primary is a stub

Standard key hygiene keeps the primary secret offline (`sec#` in `--list-secret-keys`). `--passwd` and `--edit-key` → `passwd` both operate on the **primary**, so on a stub they fail with:

```
error changing passphrase: No secret key
```

Go below the OpenPGP layer instead — gpg-agent's `PASSWD` acts on a **keygrip**, which is the subkey's own identity:

```bash
gpg --with-keygrip --list-secret-keys <PRIMARY_ID>   # take the Keygrip under the [S] line
GNUPGHOME=$TMPHOME gpg-connect-agent "PASSWD <KEYGRIP>" /bye
```

It prompts for the current passphrase, then the new one (leave empty), and returns `OK`.

## Working sequence, with a checkpoint after every silent-failure step

Each numbered step below can fail without an error; do not proceed past a checkpoint that misses its expected value. Keep the scratch `GNUPGHOME` — never strip the passphrase on the daily-driver keyring.

```bash
# 1. scratch keyring
rm -rf "$HOME/gpgtmp" && mkdir -p "$HOME/gpgtmp" && chmod 700 "$HOME/gpgtmp"

# 2. export the subkey (prompts for the passphrase)
gpg --export-secret-subkeys '<SUBKEY_ID>!' > "$HOME/gpgtmp/sub.gpg"

# 3. import into the scratch keyring
GNUPGHOME=$HOME/gpgtmp gpg --batch --import "$HOME/gpgtmp/sub.gpg"

# 4. CHECKPOINT — expect a `sec#` line AND an `ssb` line. Empty output means the
#    import did not take; everything after this would operate on a broken keyring
#    (which reports `No secret key` from --passwd and `Bad passphrase` from the
#    agent even when the passphrase is correct).
GNUPGHOME=$HOME/gpgtmp gpg --list-secret-keys --keyid-format LONG

# 5. strip the passphrase via the agent (old passphrase -> empty -> confirm)
GNUPGHOME=$HOME/gpgtmp gpg-connect-agent "PASSWD <KEYGRIP>" /bye

# 6. CHECKPOINT — the protection flag must read C (clear), not P (protected)
GNUPGHOME=$HOME/gpgtmp gpg-connect-agent "keyinfo --list" /bye | grep KEYINFO

# 7. export unprotected — loopback is mandatory, see the --batch note above
GNUPGHOME=$HOME/gpgtmp gpg --batch --pinentry-mode loopback --passphrase '' \
  --export-secret-subkeys '<SUBKEY_ID>!' > "$HOME/gpgtmp/nopass.gpg"

# 8. CHECKPOINT — expect subkey=1 and protected=0
gpg --list-packets "$HOME/gpgtmp/nopass.gpg" 2>&1 | grep -c 'secret sub key' | sed 's/^/subkey=/'
gpg --list-packets "$HOME/gpgtmp/nopass.gpg" 2>&1 | grep -ci s2k | sed 's/^/protected=/'

# 9. upload only on the expected values, then shred the scratch keyring
gcloud secrets versions add <secret> --project=<project> --data-file="$HOME/gpgtmp/nopass.gpg"
rm -rf "$HOME/gpgtmp"
```

The agent's `keyinfo` protection field reads `P` = passphrase-protected, `C` = clear, `-` = unknown. `C` is the success value at step 6 — not `-`.

## Consumer-side: gate on signing capability, never on key presence

`gpg --list-secret-keys <id>` succeeds for a key that cannot sign unattended, so a cookbook that enables `commit.gpgsign` on presence breaks every commit the moment the key arrives — worse than leaving signing off. Gate on git's own invocation shape instead. See `~/.claude/docs/ruby-detail.md#capability-guard-not-presence`.

## Rotation is not automatic

A new secret version changes nothing by itself: the consumer cookbook's `not_if` sees a usable key already on disk and skips. Sequence: add the new version → register the new public half → delete the key from the target's keyring (`gpg --batch --yes --delete-secret-and-public-key <FPR>`, and remove the leftover `~/.gnupg/private-keys-v1.d/<KEYGRIP>.key`, which `--delete-secret-keys` can leave behind) → re-apply → retire the old registration.

## Security shape worth stating in the plan

The key on the host is unprotected by requirement, not by oversight. The mitigations that remain: only a **signing** subkey travels (it cannot certify new keys), the primary stays offline, and the subkey has an expiry. State the expiry date in the plan — it schedules a repeat of this whole procedure.

Origin: 2026-08-01 sh1-cloud (kouzoh/zp-SHIN #111, #114; shin1ohno/setup #787) — five cycles and two wasted Secret Manager versions before all three traps were separated: export preserving protection, `--batch` silently dropping the protected subkey, and `--passwd` targeting a stub primary. A broken scratch keyring (private-key file present, `--list-secret-keys` empty) masked the third as a wrong-passphrase error, which is why step 4's checkpoint exists.
