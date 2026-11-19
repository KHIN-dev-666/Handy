# KHIN-dev-666/Handy fork

Branch `cloud-stt` = upstream release tag + one patch: cloud speech-to-text.

## What the patch does
- `src-tauri/src/cloud_stt.rs`: sends the finished recording (16 kHz WAV) to an
  OpenAI-compatible `/audio/transcriptions` endpoint (Groq `whisper-large-v3` by default).
- `managers/transcription.rs`: `decode_batch` tries cloud first, falls back to the local
  model on any error; `transcribe_recording` drops the live-preview result when cloud is on.
- `settings.rs`: `cloud_stt_enabled` (default false), `cloud_stt_model`, `cloud_stt_base_url`,
  `cloud_stt_key_provider` (key read from `post_process_api_keys[<provider>]`, default `groq`).
- No UI: toggle by editing `~/Library/Application Support/com.pais.handy/settings_store.json`
  while Handy is quit.

## Build
    source ~/.cargo/env && bun install
    bunx tauri build --bundles app --config '{"bundle":{"createUpdaterArtifacts":false}}'
    # output: src-tauri/target/release/bundle/macos/Handy.app

## Updating to a new upstream release
    git fetch upstream --tags
    git rebase --onto vX.Y.Z vOLD cloud-stt   # replay the patch on the new tag
    # rebuild, then test with a 30 s recording before replacing /Applications/Handy.app
Keep `update_checks_enabled` false in settings, or the in-app updater installs stock Handy.
