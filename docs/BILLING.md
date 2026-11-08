# Billing: pay-per-use credits (TON)

A pure-Dart module (`lib/billing/`) for prepaid video credits paid in Toncoin. There are no
accounts and no server. Payments are found on chain by their transfer comment, and the balance
is kept in an encrypted, authenticated, append-only ledger on the device. It runs on Android,
Windows and Linux.

Import only `package:kiro/billing/billing.dart`.

## Flow

1. On first launch the device creates a secret **recovery code** (16 Crockford base32 chars,
   80 random bits, shown as `XXXX-XXXX-XXXX-XXXX`). The public **payment id** is 8 Crockford
   chars derived from it with SHA-256. The transfer comment is exactly `kiro-<paymentId>`.
   - Transfer comments are public on chain, so the comment never contains the recovery code.
     Knowing someone's payment id does not let another device claim that credit.
   - The recovery code restores credit after a reinstall or on another device
     (`restoreFromRecoveryCode`).
2. The user picks a duration. `priceFor(d)` returns the tier (price and clip count).
   `paymentLinks(nanotons)` builds:
   - `ton://transfer/<addr>?amount=<nanotons>&text=kiro-<id>` (any TON wallet)
   - `https://app.tonkeeper.com/transfer/<addr>?amount=<nanotons>&text=kiro-<id>` (fallback)
   - QR data (the `ton://` link)
3. After paying, `refresh()` reads the receive address's history and credits matching transfers.
4. Before a render: `reserve(d)`. On success: `commit(id)`. On failure or cancel: `release(id)`.
   Reservations left open by a crash or kill are released on the next startup.

## Rules

- **Receive address.** `UQAFkuk0FEYPDTiu_d-Hz8ynT5VDFpmR9REXbkOxICwnWZO8` (non-bounceable,
  workchain 0). It is stored XOR-masked rather than as a literal. At startup it is checked
  against a split SHA-256 digest and validated as a friendly TON address (36 bytes,
  CRC16-XMODEM). If either check fails, `BillingService.open` returns
  `BillingErrorCode.addressIntegrity` and billing stays disabled.
- **Amounts** are integer nanotons (1 TON = 10^9). Decimal strings are parsed digit by digit and
  never go through floating point.
- **Accepted payment:** an internal inbound message with value > 0 whose body is a plain text
  comment (toncenter `msg.dataText` / tonapi `text_comment`) exactly equal to
  `kiro-<paymentId>`, sent to the receive account, not bounced or aborted. Payments are deduped
  by transaction hash (normalized to lowercase hex, the same value from both providers).
- **Rejected:** jetton transfer notifications (USDT, Notcoin and other jettons), NFT messages,
  encrypted comments, raw payloads, external messages, zero-value messages, and comments that
  differ in case, whitespace or suffix. A payment sent in the wrong asset or with a wrong
  comment is not credited, and the app cannot refund it.
- **Notice** shown next to every pay button (`paymentNoticeFa` / `paymentNoticeEn`):
  - FA: «فقط تون‌کوین (TON) روی شبکهٔ TON واریز کنید. هیچ توکن یا ارز دیگری (USDT، Notcoin، Jetton و…) پذیرفته نمی‌شود و برگشت‌پذیر نیست.»
  - EN: "Send only Toncoin (TON) on the TON network. No other token or currency (USDT, Notcoin, Jettons, etc.) is accepted, and such transfers cannot be refunded."

## Prices (`PriceTable.standard()`, configurable)

| Duration | TON | ~10 s clips |
|---|---|---|
| 10 s | 0.3 | 1 |
| 20 s | 0.5 | 2 |
| 30 s | 0.7 | 3 |
| 60 s | 1.2 | 6 |
| 3 min | 3 | 18 |
| 5 min | 4.5 | 30 |
| 10 min | 8 | 60 |

Prices are fixed in TON, not in fiat. A duration
between two tiers is charged at the next tier up. Durations above 10 min are not sold.
Clip count is `ceil(seconds / 10)`.

`segment_plan.dart` → `planSegments(topic, duration)` returns N scene prompts
("Scene i of N (beat, about Xs): topic. style suffix"). The last clip is shortened so the clip
lengths add up to the target. The renderer generates the clips in order and stitches them.

## Hosts contacted

Read-only public APIs, HTTPS only, no API key, no personal data sent other than the public
receive address:

- `toncenter.com`: `GET /api/v2/getTransactions?address=<addr>&limit=50&archival=true`
  (paging with `lt` + `hash`, inclusive)
- `tonapi.io` (fallback): `GET /v2/blockchain/accounts/<addr>/transactions?limit=50&sort_order=desc`
  (paging with `before_lt`)

Each request has a 15 s timeout and 3 retries with 1 s / 2 s / 4 s backoff (on network errors,
429 and 5xx). Scans stop at the stored cursor (the newest lt already scanned), at the start of
history, or after 40 pages (2000 transactions). The anonymous toncenter limit is about 1
request per second, so call `refresh()` when the user taps "I paid" or when the screen opens.
Do not poll it in a tight loop.

## Ledger and integrity

- One file per payment id, `<appSupport>/billing/ledger_<paymentId>.bin`. Each line is one
  sealed record.
- **Sealing:** encrypt-then-MAC using only `package:crypto`. The keystream is HMAC-SHA256 in
  counter mode. The tag is HMAC-SHA256 over the previous tag, the sequence number, the nonce
  and the ciphertext. Encryption and MAC keys are derived from a 32-byte master key per
  payment id. AES-GCM would need `package:cryptography`, which is not a dependency; the
  `RecordCipher` interface allows swapping it in later (keep the chained tag).
- **Head:** the record count and last tag are stored in the `SecureKeyStore` next to the
  master key. This detects truncation, deletion and rollback to an older copy, as well as
  edits.
- **Writes:** an in-process serial queue plus an OS lock on `ledger_<id>.bin.lock` (for other
  isolates or processes). Each write goes to a temp file, is flushed, renamed over the ledger,
  and then the head is updated. A crash between the rename and the head update is recognized
  and accepted.
- **On tamper** (any MAC or JSON failure, head mismatch, missing file while the head exists,
  wrong key, or a removed tamper marker), and equally on accidental disk corruption:
  - The file is quarantined as `.tampered-<ts>`.
  - A tamper marker is written to the key store (informational; shown as a notice in Settings).
  - A new ledger is started and the next `refresh()` rebuilds every credit from the chain.
  - **Lenient by design:** nothing is forfeited and the user is never locked out. Only the local
    spend history of the damaged file is lost, so its past spends are effectively refunded.
    This is an accepted trade-off of the no-server design.
- **Balance** = credited − committed spends − open reservations (`forfeited` is always 0).

## Limits (be explicit with users and maintainers)

- Without a server, a determined user with root (Android) or admin rights (desktop) can still
  defeat this. Examples: patching the binary; deleting the ledger together with its key-store
  entries (indistinguishable from a fresh install); reinstalling the app and restoring the
  recovery code, which re-derives credits but not past spends; or using one recovery code on
  two devices at once, which lets both spend the same credit.
- HMAC + platform key store + chain re-derivation makes casual edits fail. Because tamper
  handling is lenient, deleting or corrupting the ledger resets past spends. It is not DRM.
- The address mask only stops trivial search and replace. The SHA-256 check catches a swapped
  address unless the digest is patched too.
- Release builds should use `--obfuscate --split-debug-info` and the existing Android
  hardening.

## Packages

Already in `pubspec.yaml` and used by `lib/billing`: `crypto` ^3.0.8, `http` ^1.6.0,
`path` ^1.9.1 (tests use `package:http/testing.dart`, which is part of `http`).
`flutter_secure_storage` ^9.2.4 (already present) backs the key store.

To add for the UI (not used by `lib/billing` itself):

- `url_launcher: ^6.3.1`, to open the `ton://` link, falling back to the https link.
- `qr_flutter: ^4.1.0`, to show `qrData` on desktop so the user can scan it with a phone wallet.
- Optional: `cryptography: ^2.7.0`, if you switch `RecordCipher` to AES-256-GCM.

On Linux, `flutter_secure_storage` needs `libsecret-1-dev` (build) and `libsecret-1-0`
(runtime). On Windows it uses DPAPI-protected storage.

## Key store fallback and identity backup

- The app's billing key store (`FallbackKeyStore` in `lib/features/billing/billing_controller.dart`)
  uses `flutter_secure_storage`; if that throws (a broken keystore on some devices), it falls
  back to a private file `billing/keys.json` in the app support directory instead of disabling
  paid video.
- The recovery code is also kept in `billing/identity` in the app support directory, so a lost
  key-store entry does not change the payment id. Both files are app-private and excluded from
  backup (`allowBackup=false`).

## v1.3: every paid feature, free first use, owner access

All paid actions go through `PaidGate` (`lib/billing/paid_gate.dart`), shared by the Studio
(`StudioService.gate`), the chat, the caption screen and the UI (`BillingController.gate`):

1. **Owner unlocked** → free, nothing is reserved.
2. **Billing unavailable** (could not be opened) → `BillingErrorCode.unavailable`; the UI shows
   a friendly message. Model download and the model manager are not paid and keep working.
3. **First use free** → a free reservation (`n: 0`, `free: true`, feature key `f`).
4. Otherwise the feature's price is reserved. Commit on success, release on failure or cancel;
   reservations left by a crash are released on the next start (as before).

### Prices (`FeaturePricing`, all integer nanotons)

| Feature (`PaidFeature.key`) | Price |
|---|---|
| `topic_video` | `PriceTable.standard()` tiers (10 s 0.3 … 10 min 8) |
| `scenes_video` | same tiers by the estimated output length (reading-time estimate of the timeline) |
| `editor_export` | ≤ 1 min 0.2, ≤ 5 min 0.5, ≤ 10 min 1, longer 1.5 |
| `image` | 0.1 per image |
| `ai_text` | 0.02 per generation: one chat reply, or one caption + hashtags run |

Not charged: the editor preview (first 20 s, half size, watermarked), template cards, the
image-prompt helper in the Image tab, model downloads.

### Free first use

- Once per feature per device / recovery code. Recorded twice: a ledger record (the committed
  free reservation) and a device mark in the key store (`billing.v1.free_used.<feature>`), so
  restoring another recovery code on the same device does not grant it again.
- A failed, cancelled or crashed free use stays free. While a free use is reserved, a second
  concurrent use is charged.
- Lenient: a reinstall loses both records, and a damaged ledger is rebuilt from the chain without
  its free-use records, so another free use may be granted. Accepted.

### Owner access

- One random 30-character owner code (Crockford base32, CSPRNG, shown as `XXXXXX-XXXXXX-…`).
- The app holds only a salted PBKDF2-HMAC-SHA256 hash (16-byte random salt, 210 000
  iterations, 32-byte output), XOR-masked (`lib/billing/owner_access.dart`). The code is not in
  the repository, the app or CI.
- Settings → Owner access: one field. The check runs in a background isolate
  (`Isolate.run`), so the UI does not freeze (≈0.7 s on a desktop CPU, a few seconds on slow
  phones).
- On success, a device-bound token (HMAC-SHA256 of the hash under the billing master key) is
  stored under `billing.v1.owner`; the code itself is never stored. The unlock survives
  restarts. A copied token does not work on another device. After a reinstall, enter the code
  again.
- Rotate the code: `python3 tool/owner_code/new_owner_code.py <file outside the repo>` writes a
  new code to that file (mode 600, never printed) and prints the new Dart constants to paste into
  `owner_access.dart`. Anyone with root on their own phone can still patch the binary (see
  Limits).

### Pay sheet and settings (v1.3 UI)

- One big "Pay with wallet" button opens the `ton://` link (then the https fallback) with the
  amount and the comment already filled in. QR, comment and address are only under the
  collapsed "Manual payment" section.
- Settings: payment ID, recovery code and restore are under a collapsed "Advanced / backup"
  section. Users never need to send any ID to anyone.

## Integration status (v1.2.0)

Done as described below: key store adapter and `BillingService.open` in `AppServices` (never
throws; a null service disables paid video with a friendly message), `BillingController`
(ChangeNotifier over `changes`), `StudioService.renderTopicVideo` (reserve once → one image and
one ~10 s clip per segment → stream-copy concat → optional music mux → commit; release on any
error or cancel; the power, model, topic and FFmpeg checks run before anything is reserved),
the paid video card and pay sheet in the Video tab, and Settings → Credit & recovery.

## Integration steps

1. **Key store.** In `AppServices` (`lib/app/services.dart`), adapt the existing `SecureStore`:
   ```dart
   final secure = KeystoreSecureStore();
   final billingKeys = SecureKeyStoreAdapter(onRead: secure.read, onWrite: secure.write, onDelete: secure.delete);
   ```
   `KeystoreSecureStore` sets Android options only. On Windows and Linux the federated
   `flutter_secure_storage` implementations (DPAPI / libsecret) are used automatically.
2. **Open the service** at startup, after the support directory is known:
   ```dart
   final billing = (await BillingService.open(keys: billingKeys, dataDir: supportDir)).valueOrNull;
   ```
   Keep it nullable. If it is null (address integrity or storage failure), hide or disable paid
   rendering and show a generic error. Add it to `AppServices` and provide it next to
   `StudioService`. Call `dispose()` on shutdown.
3. **StudioService** (`lib/studio/studio_service.dart`): add an optional
   `BillingService? billing`. For paid video, wrap `renderVideo`:
   ```dart
   final res = await billing.reserve(duration);
   if (res case Err(:final error)) throw StudioException('billing_${error.code.name}');
   final id = res.valueOrNull!.id;
   try {
     final path = await renderVideo(project);
     await billing.commit(id);
     return path;
   } catch (_) {
     await billing.release(id);
     rethrow;
   }
   ```
   Use `planSegments(topic, duration)` to build the per-clip prompts, render each ~10 s clip,
   then concatenate them. Reserve once for the whole video, not per clip. Cancellation must
   call `release`.
4. **Studio tab** (`lib/features/studio/video_tab.dart`):
   - Add a duration picker from `billing.prices.tiers`. Show `tier.tonText` TON and
     `tier.segments` clips for each.
   - Show `billing.balance.available` with `formatNanotons`.
   - When the balance is short, show a pay sheet with:
     - the price
     - the FA/EN notice
     - an "Open wallet" button: `launchUrl(Uri.parse(links.tonUri))`, falling back to
       `links.httpsUri` with `LaunchMode.externalApplication`
     - a QR of `links.qrData`
     - the exact comment with a copy button
     - an "I paid, check now" button that calls `refresh()` and shows the result
   - Listen to `billing.changes` to update the UI.
5. **Settings screen** (`lib/features/settings/settings_screen.dart`): add a "Credit & recovery"
   section with:
   - the balance and payment id
   - the recovery code, hidden until tapped, with a copy button and a "save this somewhere
     safe" note
   - "Restore from recovery code", which calls `restoreFromRecoveryCode` and shows its result
   - a notice when `billing.tampered` is true
6. **Error messages:** map `BillingErrorCode` to localized strings: network, rateLimited ("try
   again in a minute"), insufficientFunds, tampered, invalidCode, unsupportedDuration, storage.
   The `detail` field is for logs only and is never shown.
7. **Android:** `INTERNET` permission (already required). To let `url_launcher` resolve wallet
   apps on Android 11+, add `<queries>` entries to `AndroidManifest.xml` for
   `<intent><action android:name="android.intent.action.VIEW"/><data android:scheme="ton"/></intent>`
   and the `https` scheme.
