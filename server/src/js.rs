//! Helpers that keep the wire contract of the original JavaScript gateway: the app and the
//! model were tuned against those exact rules for whitespace, numbers and loose JSON values.

use serde_json::{Map, Value};

pub const MAX_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

/// ECMAScript WhiteSpace and LineTerminator. Differs from Unicode White_Space: U+FEFF counts,
/// U+0085 does not.
pub fn is_space(character: char) -> bool {
    matches!(character, '\t' | '\n' | '\u{0B}' | '\u{0C}' | '\r' | ' ' | '\u{A0}' | '\u{1680}'
        | '\u{2000}'..='\u{200A}' | '\u{2028}' | '\u{2029}' | '\u{202F}' | '\u{205F}' | '\u{3000}' | '\u{FEFF}')
}

pub fn trim(value: &str) -> &str {
    value.trim_matches(is_space)
}

pub fn is_blank(value: &str) -> bool {
    value.chars().all(is_space)
}

/// An integer in the range JavaScript represents exactly. `13.0` counts, as it does in JSON.parse.
pub fn safe_integer(value: &Value) -> Option<i64> {
    let number = value.as_number()?;
    if let Some(integer) = number.as_i64() {
        return (-MAX_SAFE_INTEGER..=MAX_SAFE_INTEGER).contains(&integer).then_some(integer);
    }
    if number.is_u64() {
        return None;
    }
    let float = number.as_f64()?;
    (float.fract() == 0.0 && float.abs() <= MAX_SAFE_INTEGER as f64).then_some(float as i64)
}

pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(flag) => *flag,
        Value::Number(number) => number.as_f64().is_some_and(|float| float != 0.0),
        Value::String(text) => !text.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// Own property of a JSON object; anything else has no properties.
pub fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object()?.get(key)
}

/// `value?.length` being truthy: a non-empty array or string, or an object with a truthy length.
pub fn has_length(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::String(text)) => !text.is_empty(),
        Some(Value::Object(map)) => map.get("length").is_some_and(truthy),
        _ => false,
    }
}

/// An object with exactly these keys: unknown fields are refused, never ignored.
pub fn exact_keys<'a>(value: &'a Value, expected: &[&str]) -> Option<&'a Map<String, Value>> {
    let map = value.as_object()?;
    (map.len() == expected.len() && expected.iter().all(|key| map.contains_key(*key))).then_some(map)
}

/// A string that is not blank (unless `allow_empty`) and at most `max` UTF-8 bytes.
pub fn text(value: Option<&Value>, max: usize, allow_empty: bool) -> Option<&str> {
    let text = value?.as_str()?;
    ((allow_empty || !is_blank(text)) && text.len() <= max).then_some(text)
}

pub fn ascii_alphanumeric_or(value: &str, extra: &str) -> bool {
    value.chars().all(|character| character.is_ascii_alphanumeric() || extra.contains(character))
}

/// Prefixes of provider credentials. An identifier that looks like one is never published.
pub fn credential_shaped(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    ["sk-", "sk_", "gsk_", "aiza", "nvapi-"].iter().any(|prefix| lower.starts_with(prefix))
}
