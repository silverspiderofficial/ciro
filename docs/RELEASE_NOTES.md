## Kiro v1.2.0 — Pay-per-video AI videos (TON)

- New in the Video tab: an AI video from a topic. Pick a length (10 s, 20 s, 30 s, 1, 3, 5 or 10 min); one picture is generated on the device per ~10 s clip and the clips are joined with FFmpeg into one vertical 9:16 video, with optional background music. Runs in the foreground service with progress and can be stopped.
- Prepaid credit in Toncoin (TON) with no account and no server: the app looks up, on the TON blockchain, a payment carrying this device's own comment, credits it, and deducts the price per video. Only TON is accepted; other tokens are not.
- Credit is reserved before a render and spent only when the video is finished; an error, a stop or a crash returns it.
- Pay sheet: TON-only notice, Open wallet (ton:// link with an https fallback), QR code, comment and address with copy buttons, and "I paid, check now".
- Settings → Credit & recovery: balance, payment ID, recovery code (hidden until tapped) and restore on a new install or another phone.
- Lenient by design: a damaged local credit history is rebuilt from the blockchain instead of locking anyone out.
- New network hosts (read-only, public): toncenter.com, with tonapi.io as fallback.
- Videos from your own scenes stay free.

arm64-v8a only, Android 8.0+. The image model is an optional download from Hugging Face inside the app and is needed for AI videos. Until a fixed signing key is configured, a new build may not install over an older one; uninstall first, and restore your credit with the recovery code from Settings → Credit & recovery.
