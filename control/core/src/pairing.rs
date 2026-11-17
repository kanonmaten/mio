//! The pairing code: the JSON `mio-gateway pairing-payload` prints, which the phone scans. The
//! panel draws it as a QR code and shows the addresses, never the tokens as text.

use qrcode::{Color, EcLevel, QrCode};
use serde_json::Value;

/// How long the code stays on screen (plan: hidden after 60 s or when the window loses focus).
pub const SHOW_SECONDS: u64 = 60;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pairing {
    pub ai_url: String,
    pub transcription_url: Option<String>,
    /// Dark modules row by row, `width × width`, without the quiet zone.
    pub modules: Vec<bool>,
    pub width: usize,
}

impl Pairing {
    /// Reads the payload and encodes it; `None` if it is not a Mio pairing payload.
    pub fn parse(payload: &[u8]) -> Option<Self> {
        let value: Value = serde_json::from_slice(payload).ok()?;
        if value.get("mio").and_then(Value::as_u64) != Some(1) {
            return None;
        }
        let text = |name: &str| value.get(name).and_then(Value::as_str).filter(|text| !text.is_empty()).map(str::to_owned);
        let ai_url = text("aiURL")?;
        text("aiToken")?;
        let transcription_url = text("transcriptionURL").filter(|_| text("transcriptionToken").is_some());
        // Medium correction, as `qrencode` uses by default in the installers.
        let code = QrCode::with_error_correction_level(payload.trim_ascii(), EcLevel::M).ok()?;
        let width = code.width();
        let modules = code.to_colors().into_iter().map(|color| color == Color::Dark).collect();
        Some(Self { ai_url, transcription_url, modules, width })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAYLOAD: &str = r#"{"mio":1,"aiURL":"https://pc.tail1234.ts.net:8443","aiToken":"abc","transcriptionURL":"https://pc.tail1234.ts.net","transcriptionToken":"def"}"#;

    #[test]
    fn the_payload_becomes_a_square_code_and_addresses() {
        let pairing = Pairing::parse(format!("{PAYLOAD}\n").as_bytes()).expect("valid payload");
        assert_eq!(pairing.ai_url, "https://pc.tail1234.ts.net:8443");
        assert_eq!(pairing.transcription_url.as_deref(), Some("https://pc.tail1234.ts.net"));
        assert_eq!(pairing.modules.len(), pairing.width * pairing.width);
        // Finder pattern in the top-left corner: a dark 7×7 border.
        assert!((0..7).all(|i| pairing.modules[i] && pairing.modules[i * pairing.width]));
        assert!(!pairing.modules[pairing.width + 1]);
    }

    #[test]
    fn other_text_is_not_a_pairing_code() {
        assert!(Pairing::parse(b"not json").is_none());
        assert!(Pairing::parse(br#"{"mio":2,"aiURL":"x","aiToken":"y"}"#).is_none());
        assert!(Pairing::parse(br#"{"mio":1,"aiURL":"https://a:8443"}"#).is_none());
        let ai_only = Pairing::parse(br#"{"mio":1,"aiURL":"https://a:8443","aiToken":"t","transcriptionURL":null,"transcriptionToken":null}"#).unwrap();
        assert_eq!(ai_only.transcription_url, None);
    }
}
