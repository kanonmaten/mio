//! The transcription page's model: Pianissimo's settings in `/etc/mio-transcription.conf` with
//! the service's own defaults, and the changes shown before saving.

use serde_json::{Map, Value, json};

use crate::ai_settings::{Change, GatewayFile};
use crate::settings::check_transcription_value;

/// Pianissimo's defaults when a line is missing (backend.py, app.py).
const DEFAULT_PRECISION: &str = "fp16";
const DEFAULT_BOOST: f64 = 1.0;

fn flag(value: Option<&str>, default: bool) -> bool {
    match value.map(|value| value.trim().to_lowercase()) {
        Some(value) if ["1", "true", "on", "ja"].contains(&value.as_str()) => true,
        Some(value) if ["0", "false", "off", "nej"].contains(&value.as_str()) => false,
        _ => default,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptionForm {
    /// `fp16` or `fp32`.
    pub precision: String,
    pub preprocess: bool,
    pub speaker_labels: bool,
    /// Phrase boosting strength, 0–2 in steps of 0.1.
    pub boost: f64,
    /// "Byt till senaste": drop the pinned speaker model so the next install picks the newest.
    pub unpin_diarization: bool,
}

impl TranscriptionForm {
    pub fn from_file(file: &GatewayFile) -> Self {
        let value = |key: &str| file.values.get(key).map(String::as_str).filter(|value| !value.trim().is_empty());
        Self {
            precision: value("MIO_PRECISION").unwrap_or(DEFAULT_PRECISION).trim().to_owned(),
            preprocess: flag(value("MIO_PREPROCESS"), true),
            speaker_labels: flag(value("MIO_SPEAKER_LABELS"), true),
            boost: value("MIO_VOCABULARY_BOOST").and_then(|boost| boost.trim().parse().ok()).unwrap_or(DEFAULT_BOOST),
            unpin_diarization: false,
        }
    }

    /// Above 1.0 listed words may be written although they were not said (README, Egna ord).
    pub fn boost_is_high(&self) -> bool {
        self.boost > DEFAULT_BOOST + 1e-9
    }

    fn boost_text(&self) -> String {
        format!("{:.1}", (self.boost * 10.0).round() / 10.0)
    }

    /// Settings whose effective value differs from the file, as Pianissimo would read them.
    pub fn changes(&self, file: &GatewayFile) -> Vec<Change> {
        let current = Self::from_file(file);
        let before = |key: &str| file.values.get(key).filter(|value| !value.trim().is_empty()).cloned();
        let on_off = |on: bool| if on { "1" } else { "0" }.to_owned();
        let mut changes = Vec::new();
        let mut push = |key: &str, differs: bool, after: Option<String>| {
            if differs {
                changes.push(Change { key: key.to_owned(), before: before(key), after });
            }
        };
        push("MIO_PRECISION", self.precision != current.precision, Some(self.precision.clone()));
        push("MIO_PREPROCESS", self.preprocess != current.preprocess, Some(on_off(self.preprocess)));
        push("MIO_SPEAKER_LABELS", self.speaker_labels != current.speaker_labels, Some(on_off(self.speaker_labels)));
        push("MIO_VOCABULARY_BOOST", self.boost_text() != current.boost_text(), Some(self.boost_text()));
        push("MIO_DIARIZATION_REVISION", self.unpin_diarization && before("MIO_DIARIZATION_REVISION").is_some(), None);
        changes
    }

    pub fn problems(&self) -> Vec<String> {
        [("MIO_PRECISION", self.precision.clone()), ("MIO_VOCABULARY_BOOST", self.boost_text())]
            .into_iter()
            .filter_map(|(key, value)| check_transcription_value(key, &value).err().map(str::to_owned))
            .collect()
    }

    pub fn request(changes: &[Change]) -> Value {
        let set: Map<String, Value> = changes.iter().filter_map(|change| Some((change.key.clone(), Value::String(change.after.clone()?)))).collect();
        let remove: Vec<Value> = changes.iter().filter(|change| change.after.is_none()).map(|change| Value::String(change.key.clone())).collect();
        json!({ "set": set, "remove": remove })
    }
}

/// Sorts the phrases alphabetically (Swedish letters after z by byte order is close enough for
/// a list of names), keeping comment lines first and dropping blank lines and duplicates.
pub fn sort_vocabulary(text: &str) -> String {
    let mut comments = Vec::new();
    let mut phrases: Vec<String> = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('#') {
            comments.push(line.to_owned());
        } else {
            let phrase = trimmed.split_whitespace().collect::<Vec<_>>().join(" ");
            if !phrases.contains(&phrase) {
                phrases.push(phrase);
            }
        }
    }
    phrases.sort_by_key(|phrase| phrase.to_lowercase());
    let mut sorted = comments;
    sorted.extend(phrases);
    let mut text = sorted.join("\n");
    text.push('\n');
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(values: &[(&str, &str)]) -> GatewayFile {
        GatewayFile { values: values.iter().map(|(key, value)| ((*key).to_owned(), (*value).to_owned())).collect(), secrets: Default::default() }
    }

    #[test]
    fn defaults_are_pianissimos_and_unchanged_defaults_write_nothing() {
        let installed = file(&[("MIO_MODEL_REVISION", "0123456789abcdef0123456789abcdef01234567")]);
        let form = TranscriptionForm::from_file(&installed);
        assert_eq!((form.precision.as_str(), form.preprocess, form.speaker_labels, form.boost), ("fp16", true, true, 1.0));
        assert!(form.changes(&installed).is_empty());
        let off = file(&[("MIO_PREPROCESS", "nej"), ("MIO_SPEAKER_LABELS", "0"), ("MIO_PRECISION", "fp32")]);
        let form = TranscriptionForm::from_file(&off);
        assert_eq!((form.precision.as_str(), form.preprocess, form.speaker_labels), ("fp32", false, false));
    }

    #[test]
    fn changes_name_the_lines_pianissimo_reads() {
        let installed = file(&[("MIO_DIARIZATION_REVISION", "0123456789abcdef0123456789abcdef01234567")]);
        let mut form = TranscriptionForm::from_file(&installed);
        form.precision = "fp32".into();
        form.speaker_labels = false;
        form.boost = 1.5;
        form.unpin_diarization = true;
        assert!(form.boost_is_high());
        let changes = form.changes(&installed);
        let keys: Vec<(&str, Option<&str>)> = changes.iter().map(|change| (change.key.as_str(), change.after.as_deref())).collect();
        assert_eq!(keys, [("MIO_PRECISION", Some("fp32")), ("MIO_SPEAKER_LABELS", Some("0")), ("MIO_VOCABULARY_BOOST", Some("1.5")), ("MIO_DIARIZATION_REVISION", None)]);
        assert_eq!(TranscriptionForm::request(&changes)["remove"], json!(["MIO_DIARIZATION_REVISION"]));
        assert!(form.problems().is_empty());
        form.boost = 2.4;
        assert_eq!(form.problems().len(), 1);
    }

    #[test]
    fn vocabulary_sorting_keeps_comments_and_drops_duplicates() {
        assert_eq!(sort_vocabulary("# Egna ord\nÅsa Lindqvist\n\nbiblioteket\nÅsa  Lindqvist\nAnna\n"), "# Egna ord\nAnna\nbiblioteket\nÅsa Lindqvist\n");
    }
}
