//! Fork addition: cloud speech-to-text through an OpenAI-compatible
//! `/audio/transcriptions` endpoint (Groq by default).
//!
//! Upstream Handy is local-only by design; this module is the single place
//! the fork talks to a cloud STT service. Callers fall back to the local
//! model on any error returned from here.

use std::io::Cursor;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use log::{info, warn};

use crate::settings::AppSettings;

const SAMPLE_RATE: u32 = 16_000;
/// Whisper's prompt is capped at ~224 tokens; keep the vocabulary hint short.
const MAX_PROMPT_CHARS: usize = 400;

/// One keep-alive client for the whole process, so each dictation reuses the
/// TLS connection instead of paying a fresh handshake.
fn client() -> &'static reqwest::blocking::Client {
    static CLIENT: OnceLock<reqwest::blocking::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::blocking::Client::builder()
            .user_agent(concat!("Handy-fork/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .pool_idle_timeout(Duration::from_secs(300))
            .build()
            .expect("build cloud STT HTTP client")
    })
}

/// Whether cloud transcription is switched on and has a key to use.
pub fn is_active(settings: &AppSettings) -> bool {
    settings.cloud_stt_enabled && api_key(settings).is_some()
}

fn api_key(settings: &AppSettings) -> Option<String> {
    settings
        .post_process_api_keys
        .get(&settings.cloud_stt_key_provider)
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

/// Encodes 16 kHz mono f32 PCM as an in-memory 16-bit WAV file.
fn encode_wav(audio: &[f32]) -> Result<Vec<u8>> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut buf = Cursor::new(Vec::with_capacity(audio.len() * 2 + 64));
    {
        let mut writer = hound::WavWriter::new(&mut buf, spec)?;
        for &s in audio {
            let v = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
            writer.write_sample(v)?;
        }
        writer.finalize()?;
    }
    Ok(buf.into_inner())
}

fn vocabulary_prompt(settings: &AppSettings) -> Option<String> {
    let mut prompt = String::new();
    for word in settings.custom_words.iter().map(|w| w.trim()) {
        if word.is_empty() {
            continue;
        }
        if prompt.chars().count() + word.chars().count() + 1 > MAX_PROMPT_CHARS {
            break;
        }
        if !prompt.is_empty() {
            prompt.push('、');
        }
        prompt.push_str(word);
    }
    (!prompt.is_empty()).then_some(prompt)
}

/// Transcribes `audio` (16 kHz mono) in the cloud. `language` is a Whisper
/// language code, or `None` to let the service detect it.
///
/// Runs on its own OS thread so the blocking HTTP client never runs inside an
/// async runtime, whatever thread the caller is on.
pub fn transcribe(settings: &AppSettings, audio: &[f32], language: Option<&str>) -> Result<String> {
    let key = api_key(settings).ok_or_else(|| anyhow!("no cloud STT API key"))?;
    let url = format!(
        "{}/audio/transcriptions",
        settings.cloud_stt_base_url.trim_end_matches('/')
    );
    let model = settings.cloud_stt_model.clone();
    let prompt = vocabulary_prompt(settings);
    let language = language
        .filter(|l| !l.is_empty() && *l != "auto")
        .map(str::to_string);
    let wav = encode_wav(audio)?;
    let audio_secs = audio.len() as f64 / SAMPLE_RATE as f64;

    let started = Instant::now();
    let handle = std::thread::spawn(move || -> Result<String> {
        let file = reqwest::blocking::multipart::Part::bytes(wav)
            .file_name("audio.wav")
            .mime_str("audio/wav")?;
        let mut form = reqwest::blocking::multipart::Form::new()
            .part("file", file)
            .text("model", model)
            .text("response_format", "json")
            .text("temperature", "0");
        if let Some(language) = language {
            form = form.text("language", language);
        }
        if let Some(prompt) = prompt {
            form = form.text("prompt", prompt);
        }
        let resp = client()
            .post(&url)
            .bearer_auth(key)
            .multipart(form)
            .send()
            .context("cloud STT request failed")?;
        let status = resp.status();
        let body = resp.text().context("cloud STT response unreadable")?;
        if !status.is_success() {
            return Err(anyhow!(
                "cloud STT HTTP {}: {}",
                status,
                body.chars().take(200).collect::<String>()
            ));
        }
        let json: serde_json::Value =
            serde_json::from_str(&body).context("cloud STT response not JSON")?;
        json.get("text")
            .and_then(|t| t.as_str())
            .map(|t| t.trim().to_string())
            .ok_or_else(|| anyhow!("cloud STT response has no text"))
    });
    let result = handle
        .join()
        .map_err(|_| anyhow!("cloud STT thread panicked"))?;
    match &result {
        Ok(_) => info!(
            "Cloud transcription ({}) completed in {:.2}s for {:.2}s of audio",
            settings.cloud_stt_model,
            started.elapsed().as_secs_f64(),
            audio_secs
        ),
        Err(e) => warn!("Cloud transcription failed, falling back to local: {e:#}"),
    }
    result
}
