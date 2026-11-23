//! Which settings the panel may change, and the limits each service enforces.
//!
//! The gateway checks its own file (`mio-gateway kontrollera-konfiguration`); the rules here
//! decide what the panel may write at all and mirror Pianissimo's parsing in
//! `transcription-server/mio_transcription/` so a value the service would refuse is never saved.

/// Settings files the helper may change. Nothing else under `/etc` is reachable.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SettingsFile {
    Gateway,
    Transcription,
}

impl SettingsFile {
    pub const ALL: [SettingsFile; 2] = [SettingsFile::Gateway, SettingsFile::Transcription];

    /// The name used on the helper's command line.
    pub fn id(self) -> &'static str {
        match self {
            SettingsFile::Gateway => "gateway",
            SettingsFile::Transcription => "transkription",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|file| file.id() == id)
    }

    /// The path below the system root.
    pub fn path(self) -> &'static str {
        match self {
            SettingsFile::Gateway => "etc/mio-gateway/gateway.env",
            SettingsFile::Transcription => "etc/mio-transcription.conf",
        }
    }

    /// Plain settings the panel may write. Keys and tokens have their own commands.
    pub fn writable_keys(self) -> &'static [&'static str] {
        match self {
            SettingsFile::Gateway => &[
                "MIO_AI_PROVIDER",
                "MIO_AI_MODEL",
                "MIO_AI_TASK_PROFILES",
                "MIO_REQUESTS_PER_MINUTE",
                "MIO_TOKENS_PER_MINUTE",
                "MIO_TOKENS_PER_MINUTE_ANTHROPIC",
                "MIO_TOKENS_PER_MINUTE_MISTRAL",
                "MIO_TOKENS_PER_MINUTE_NVIDIA",
                "MIO_TOKENS_PER_MINUTE_OPENAI",
                "MIO_TOKENS_PER_MINUTE_OPENROUTER",
                "MIO_TOKENS_PER_MINUTE_GEMINI",
                "MIO_TOKENS_PER_DAY",
                "MIO_REQUESTS_PER_DAY",
                "MIO_LESSON_INTERVAL_SECONDS",
                "MIO_LESSON_REASONING",
                "MIO_MAX_OUTPUT_TOKENS_ASK",
                "MIO_MAX_OUTPUT_TOKENS_EVERYDAY",
                "MIO_MAX_OUTPUT_TOKENS_LESSON",
            ],
            SettingsFile::Transcription => &[
                "MIO_PRECISION",
                "MIO_PREPROCESS",
                "MIO_SPEAKER_LABELS",
                "MIO_VOCABULARY_BOOST",
                "MIO_MODEL_REVISION",
                "MIO_DIARIZATION_REVISION",
            ],
        }
    }

    /// The token variable `byt-token` replaces.
    pub fn token_key(self) -> &'static str {
        match self {
            SettingsFile::Gateway => "MIO_GATEWAY_TOKEN",
            SettingsFile::Transcription => "MIO_TRANSCRIPTION_TOKEN",
        }
    }
}

/// Whether a variable holds a secret: shown only as set or not set, never sent to the panel.
pub fn is_secret_key(key: &str) -> bool {
    key.ends_with("_KEY") || key.ends_with("_TOKEN") || key.ends_with("_SECRET") || key.contains("API_KEY")
}

/// Provider key variables the helper may set. Must match `PROVIDERS` in
/// `server/src/model_profiles.rs`; a test keeps them in step.
pub const PROVIDER_SECRET_KEYS: &[&str] = &["GROQ_API_KEY", "ANTHROPIC_API_KEY", "MISTRAL_API_KEY", "NVIDIA_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "GEMINI_API_KEY"];

/// The vocabulary file below the system root (`root:mio-transcription 0640`).
pub const VOCABULARY_PATH: &str = "etc/mio-transcription-vocabulary.txt";
/// Pianissimo uses at most this many phrases (`MAX_VOCABULARY`).
pub const VOCABULARY_MAX_PHRASES: usize = 500;
/// Longer phrases are skipped by Pianissimo.
pub const VOCABULARY_MAX_BYTES: usize = 100;
/// The panel refuses to write a larger file; Pianissimo reads at most 1,000,000 characters.
pub const VOCABULARY_MAX_FILE_BYTES: usize = 200_000;

/// Checks a Pianissimo value the way the service parses it. `Err` holds a Swedish message.
pub fn check_transcription_value(key: &str, value: &str) -> Result<(), &'static str> {
    let flag = |value: &str| {
        let value = value.trim().to_lowercase();
        value.is_empty() || ["1", "true", "on", "ja", "0", "false", "off", "nej"].contains(&value.as_str())
    };
    let commit = |value: &str| value.len() == 40 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    let valid = match key {
        // backend.parse_precision: empty means fp16.
        "MIO_PRECISION" => ["", "fp16", "fp32"].contains(&value.trim()),
        // app.env_flag
        "MIO_PREPROCESS" | "MIO_SPEAKER_LABELS" => flag(value),
        // backend: [0-2](\.[0-9]{1,2})? and at most 2.
        "MIO_VOCABULARY_BOOST" => {
            let boost = value.trim();
            let shaped = match boost.split_once('.') {
                None => boost.len() == 1,
                Some((whole, fraction)) => whole.len() == 1 && (1..=2).contains(&fraction.len()) && fraction.bytes().all(|byte| byte.is_ascii_digit()),
            };
            boost.is_empty() || (shaped && matches!(boost.as_bytes()[0], b'0'..=b'2') && boost.parse::<f64>().is_ok_and(|number| number <= 2.0))
        }
        "MIO_MODEL_REVISION" => commit(value),
        "MIO_DIARIZATION_REVISION" => commit(value) || value.is_empty(),
        _ => return Err("Den inställningen går inte att ändra från panelen."),
    };
    if valid {
        Ok(())
    } else {
        Err(match key {
            "MIO_PRECISION" => "Precisionen måste vara fp16 eller fp32.",
            "MIO_PREPROCESS" | "MIO_SPEAKER_LABELS" => "Värdet måste vara på (1) eller av (0).",
            "MIO_VOCABULARY_BOOST" => "Styrkan måste vara mellan 0 och 2 med högst två decimaler.",
            _ => "En version måste vara en hel commit (40 tecken 0–9 och a–f).",
        })
    }
}

/// What the vocabulary editor shows: how many phrases Pianissimo will use and which lines it skips.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VocabularyReport {
    pub phrases: usize,
    /// One-based line numbers of phrases over 100 bytes or with control characters.
    pub too_long: Vec<usize>,
    /// One-based line numbers of phrases that repeat an earlier one.
    pub duplicates: Vec<usize>,
    /// Phrases after the first 500 that Pianissimo ignores.
    pub ignored_over_limit: usize,
}

/// Reads a vocabulary like `core.parse_vocabulary` in Pianissimo.
pub fn check_vocabulary(text: &str) -> VocabularyReport {
    let mut report = VocabularyReport::default();
    let mut seen: Vec<String> = Vec::new();
    for (index, line) in text.lines().enumerate() {
        let phrase = line.split_whitespace().collect::<Vec<_>>().join(" ");
        if phrase.is_empty() || phrase.starts_with('#') {
            continue;
        }
        if phrase.len() > VOCABULARY_MAX_BYTES || phrase.chars().any(|character| (character as u32) < 32 || character as u32 == 127) {
            report.too_long.push(index + 1);
            continue;
        }
        if seen.contains(&phrase) {
            report.duplicates.push(index + 1);
            continue;
        }
        if seen.len() == VOCABULARY_MAX_PHRASES {
            report.ignored_over_limit += 1;
            continue;
        }
        seen.push(phrase);
    }
    report.phrases = seen.len();
    report
}

/// Whether the helper may write this vocabulary: UTF-8 text without NUL, within the size limit.
pub fn vocabulary_is_writable(bytes: &[u8]) -> Result<&str, &'static str> {
    if bytes.len() > VOCABULARY_MAX_FILE_BYTES {
        return Err("Ordlistan är för stor.");
    }
    let text = std::str::from_utf8(bytes).map_err(|_| "Ordlistan måste vara UTF-8-text.")?;
    if text.contains('\0') {
        return Err("Ordlistan innehåller otillåtna tecken.");
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcription_values_follow_pianissimos_parser() {
        for (key, value) in [
            ("MIO_PRECISION", "fp16"), ("MIO_PRECISION", "fp32"), ("MIO_PRECISION", ""),
            ("MIO_PREPROCESS", "0"), ("MIO_PREPROCESS", "Ja"), ("MIO_SPEAKER_LABELS", "off"),
            ("MIO_VOCABULARY_BOOST", "0"), ("MIO_VOCABULARY_BOOST", "1.5"), ("MIO_VOCABULARY_BOOST", "2.0"), ("MIO_VOCABULARY_BOOST", "0.25"),
            ("MIO_MODEL_REVISION", "0123456789abcdef0123456789abcdef01234567"), ("MIO_DIARIZATION_REVISION", ""),
        ] {
            assert_eq!(check_transcription_value(key, value), Ok(()), "{key}={value}");
        }
        for (key, value) in [
            ("MIO_PRECISION", "bf16"), ("MIO_PREPROCESS", "kanske"), ("MIO_VOCABULARY_BOOST", "2.1"),
            ("MIO_VOCABULARY_BOOST", "3"), ("MIO_VOCABULARY_BOOST", "1.234"), ("MIO_VOCABULARY_BOOST", "-1"), ("MIO_VOCABULARY_BOOST", "1."),
            ("MIO_MODEL_REVISION", "main"), ("MIO_MODEL_REVISION", "0123456789ABCDEF0123456789abcdef01234567"),
            ("MIO_TRANSCRIPTION_TOKEN", "x"), ("PATH", "/tmp"),
        ] {
            assert!(check_transcription_value(key, value).is_err(), "{key}={value}");
        }
    }

    #[test]
    fn secrets_are_recognised_and_never_writable_as_plain_settings() {
        for file in SettingsFile::ALL {
            assert!(file.writable_keys().iter().all(|key| !is_secret_key(key)));
            assert!(is_secret_key(file.token_key()));
            assert_eq!(SettingsFile::from_id(file.id()), Some(file));
        }
        assert!(PROVIDER_SECRET_KEYS.iter().all(|key| is_secret_key(key)));
        assert_eq!(SettingsFile::from_id("/etc/passwd"), None);
    }

    /// The helper may only set keys the gateway reads: every `secret_variable` in its `PROVIDERS`.
    #[test]
    fn provider_keys_match_the_gateways_providers() {
        let source = include_str!("../../../server/src/model_profiles.rs");
        let mut gateway: Vec<&str> = source
            .split("secret_variable: \"")
            .skip(1)
            .filter_map(|rest| rest.split('"').next())
            .collect();
        gateway.sort_unstable();
        let mut ours = PROVIDER_SECRET_KEYS.to_vec();
        ours.sort_unstable();
        assert_eq!(ours, gateway);
    }

    #[test]
    fn vocabulary_report_matches_pianissimo() {
        let long = "x".repeat(101);
        let text = format!("# kommentar\nÅsa Lindqvist\n  Åsa   Lindqvist \n\n{long}\nInstallationsteknik\n");
        let report = check_vocabulary(&text);
        assert_eq!(report, VocabularyReport { phrases: 2, too_long: vec![5], duplicates: vec![3], ignored_over_limit: 0 });
        let many: String = (0..503).map(|number| format!("ord{number}\n")).collect();
        let report = check_vocabulary(&many);
        assert_eq!((report.phrases, report.ignored_over_limit), (500, 3));
        // 100 bytes is allowed, counted in UTF-8 bytes: 50 "å" are 100 bytes.
        assert_eq!(check_vocabulary(&"å".repeat(50)).phrases, 1);
        assert_eq!(check_vocabulary(&"å".repeat(51)).too_long, vec![1]);
    }

    #[test]
    fn only_reasonable_text_is_writable_as_vocabulary() {
        assert!(vocabulary_is_writable("Åsa\n".as_bytes()).is_ok());
        assert!(vocabulary_is_writable(b"\xff\n").is_err());
        assert!(vocabulary_is_writable(b"a\0b").is_err());
        assert!(vocabulary_is_writable(&vec![b'a'; VOCABULARY_MAX_FILE_BYTES + 1]).is_err());
    }
}
