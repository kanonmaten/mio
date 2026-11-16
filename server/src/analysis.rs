//! Payload and answer validation. Transcript text is untrusted source material, never an
//! instruction or a tool request. The shape of an answer is all or nothing; its items are
//! checked one by one, and an item the source cannot prove is dropped, never passed on.

use std::collections::HashSet;

use serde_json::{Map, Value, json};
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;

use crate::js::{exact_keys, is_blank, is_space, text, trim};
use crate::time::{is_instant, is_scheduled, is_time_zone, with_offset};

/// A payload or answer that breaks the contract. Callers map it to one fixed public code.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Invalid;

type Checked<T> = Result<T, Invalid>;

fn ensure(condition: bool) -> Checked<()> {
    if condition { Ok(()) } else { Err(Invalid) }
}

// ---- Strict JSON schemas sent to the provider -------------------------------------------------

fn object(properties: Vec<(&str, Value)>) -> Value {
    let required: Vec<Value> = properties.iter().map(|(name, _)| json!(name)).collect();
    let properties: Map<String, Value> = properties.into_iter().map(|(name, schema)| (name.to_owned(), schema)).collect();
    json!({ "type": "object", "properties": properties, "required": required, "additionalProperties": false })
}

fn string() -> Value {
    json!({ "type": "string" })
}

fn string_list() -> Value {
    json!({ "type": "array", "items": { "type": "string" } })
}

fn candidate_properties(kinds: &[&str], replaces: bool) -> Vec<(&'static str, Value)> {
    let mut properties = vec![
        ("kind", json!({ "type": "string", "enum": kinds })),
        ("title", string()), ("body", string()),
        ("scheduledAt", json!({ "type": ["string", "null"] })),
        ("sourceIDs", string_list()), ("evidence", string()),
    ];
    if replaces {
        properties.push(("replacesID", json!({ "type": ["string", "null"] })));
    }
    properties
}

fn list_of(item: Value) -> Value {
    json!({ "type": "array", "items": item })
}

fn format(name: &str, schema: Value) -> Value {
    json!({ "type": "json_schema", "name": name, "strict": true, "schema": schema })
}

fn analysis_schema(replaces: bool) -> Value {
    object(vec![
        ("candidates", list_of(object(candidate_properties(&["plan", "task", "note"], replaces)))),
        ("highlights", list_of(object(vec![("text", string()), ("sourceIDs", string_list()), ("evidence", string())]))),
        ("uncertainties", string_list()),
    ])
}

pub fn analysis_format() -> Value {
    format("mio_analysis", analysis_schema(false))
}

pub fn analysis_v2_format() -> Value {
    format("mio_analysis_v2", analysis_schema(true))
}

pub fn ask_format() -> Value {
    format("mio_answer", object(vec![("answer", string())]))
}

pub fn lesson_format() -> Value {
    format("mio_lesson_notes_v1", object(vec![
        ("candidates", list_of(object(candidate_properties(&["plan", "task"], false)))),
        ("sections", list_of(object(vec![("heading", string()), ("body", string()),
            ("sourceIDs", string_list()), ("evidence", string())]))),
        ("uncertainties", string_list()),
    ]))
}

// ---- Request payloads ---------------------------------------------------------------------------

/// The question the user approved and at most six chosen excerpts. Unknown fields are refused.
pub fn validate_ask_payload(value: &Value) -> Result<(), &'static str> {
    let question = exact_keys(value, &["question", "context"]).and_then(|map| map["question"].as_str());
    let context = value.get("context").and_then(Value::as_array);
    let (Some(question), Some(context)) = (question, context) else { return Err("invalid_request") };
    if is_blank(question) || question.len() > 2_000 || context.len() > 6 {
        return Err("invalid_request");
    }
    let mut total = 0;
    for item in context {
        let fields = exact_keys(item, &["label", "text"]);
        let label = fields.and_then(|map| text(map.get("label"), 200, false));
        let body = fields.and_then(|map| text(map.get("text"), 4_000, false));
        let (Some(label), Some(body)) = (label, body) else { return Err("invalid_context") };
        total += label.len() + body.len();
    }
    if total > 10_000 { Err("invalid_context") } else { Ok(()) }
}

fn is_fragment_id(id: &str) -> bool {
    let Some((uuid, index)) = id.split_once(':') else { return false };
    uuid.len() == 36 && uuid.chars().all(|character| character.is_ascii_hexdigit() || character == '-')
        && (1..=6).contains(&index.len()) && index.chars().all(|character| character.is_ascii_digit())
}

/// The shared source contract: 1-16 fragments with unique IDs, a clock time each and at most
/// 16,000 bytes of text. A backlog may send twelve new and three context sources in one call.
fn validate_sources(mode: &Value, time_zone: Option<&Value>, fragments: &[&Value]) -> Checked<()> {
    ensure(matches!(mode.as_str(), Some("everyday" | "lesson")))?;
    let time_zone = text(time_zone, 100, false).ok_or(Invalid)?;
    ensure((1..=16).contains(&fragments.len()) && is_time_zone(time_zone))?;
    let mut ids = HashSet::new();
    let mut total = 0;
    for fragment in fragments {
        let fields = exact_keys(fragment, &["id", "text", "occurredAt"]).ok_or(Invalid)?;
        let id = text(fields.get("id"), 80, false).ok_or(Invalid)?;
        let body = text(fields.get("text"), 4_000, false).ok_or(Invalid)?;
        ensure(is_fragment_id(id) && ids.insert(id) && fields["occurredAt"].as_str().is_some_and(is_instant))?;
        total += body.len();
    }
    ensure(total <= 16_000)
}

pub fn validate_analysis_payload(value: &Value) -> Checked<()> {
    let fields = exact_keys(value, &["mode", "timeZone", "fragments"]).ok_or(Invalid)?;
    let fragments: Vec<&Value> = fields["fragments"].as_array().ok_or(Invalid)?.iter().collect();
    validate_sources(&fields["mode"], fields.get("timeZone"), &fragments)
}

fn text_bytes(fragments: &[Value]) -> usize {
    fragments.iter().filter_map(|fragment| fragment.get("text")?.as_str()).map(str::len).sum()
}

pub fn validate_lesson_payload(value: &Value) -> Checked<()> {
    validate_analysis_payload(value)?;
    ensure(value["mode"] == "lesson" && text_bytes(value["fragments"].as_array().ok_or(Invalid)?) <= 3_500)
}

fn is_uuid(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36 && bytes.iter().enumerate().all(|(index, byte)| match index {
        8 | 13 | 18 | 23 => *byte == b'-',
        _ => byte.is_ascii_hexdigit(),
    })
}

const KINDS: [&str; 3] = ["plan", "task", "note"];

pub fn validate_analysis_v2_payload(value: &Value) -> Checked<()> {
    let fields = exact_keys(value, &["mode", "timeZone", "fragments", "contextFragments", "priorDecisions", "contextLimited"])
        .ok_or(Invalid)?;
    let (Some(fragments), Some(context), Some(decisions)) = (fields["fragments"].as_array(),
        fields["contextFragments"].as_array(), fields["priorDecisions"].as_array()) else { return Err(Invalid) };
    ensure(fields["mode"] == "everyday" && fields["contextLimited"].is_boolean()
        && !fragments.is_empty() && decisions.len() <= 12)?;
    // The source contract also enforces disjoint IDs and the shared sixteen-source/UTF-8 budget.
    let sources: Vec<&Value> = fragments.iter().chain(context).collect();
    validate_sources(&fields["mode"], fields.get("timeZone"), &sources)?;
    ensure(text_bytes(context) <= 4_000)?;
    let context_ids: HashSet<&str> = context.iter().filter_map(|fragment| fragment["id"].as_str()).collect();
    let mut decision_ids = HashSet::new();
    for decision in decisions {
        let item = exact_keys(decision, &["id", "kind", "sourceIDs", "isOpen"]).ok_or(Invalid)?;
        let id = item["id"].as_str().filter(|id| is_uuid(id)).ok_or(Invalid)?;
        let source_ids = item["sourceIDs"].as_array().ok_or(Invalid)?;
        let mut seen = HashSet::new();
        ensure(decision_ids.insert(id.to_ascii_lowercase())
            && item["kind"].as_str().is_some_and(|kind| KINDS.contains(&kind))
            && item["isOpen"].is_boolean() && (1..=8).contains(&source_ids.len())
            && source_ids.iter().all(|id| id.as_str().is_some_and(|id| context_ids.contains(id) && seen.insert(id))))?;
    }
    Ok(())
}

// ---- Grounding ----------------------------------------------------------------------------------

fn is_ignored(character: char) -> bool {
    use GeneralCategory::*;
    is_space(character) || matches!(get_general_category(character),
        ConnectorPunctuation | DashPunctuation | OpenPunctuation | ClosePunctuation | InitialPunctuation
        | FinalPunctuation | OtherPunctuation | MathSymbol | CurrencySymbol | ModifierSymbol | OtherSymbol)
}

fn is_mark(character: char) -> bool {
    matches!(get_general_category(character),
        GeneralCategory::NonspacingMark | GeneralCategory::SpacingMark | GeneralCategory::EnclosingMark)
}

/// Letters and digits only, case-folded and NFKC-normalized, with the byte span of the source
/// cluster each folded character came from.
struct Folded {
    text: String,
    /// Byte offset in `text` where each folded character starts.
    starts: Vec<usize>,
    spans: Vec<(usize, usize)>,
}

fn fold(value: &str) -> Folded {
    let mut folded = Folded { text: String::new(), starts: Vec::new(), spans: Vec::new() };
    let mut cluster = String::new();
    let mut start = 0;
    let mut flush = |cluster: &mut String, start: usize, end: usize| {
        if !cluster.is_empty() && !cluster.chars().any(is_ignored) {
            for character in cluster.nfkc().collect::<String>().to_lowercase().chars() {
                folded.starts.push(folded.text.len());
                folded.text.push(character);
                folded.spans.push((start, end));
            }
        }
        cluster.clear();
    };
    for (offset, character) in value.char_indices() {
        if !cluster.is_empty() && is_mark(character) {
            cluster.push(character);
        } else {
            flush(&mut cluster, start, offset);
            cluster.push(character);
            start = offset;
        }
    }
    flush(&mut cluster, start, value.len());
    folded
}

/// Splits a quote where the model joined two passages: `…`, three or more dots, or `[...]`.
fn split_ellipsis(evidence: &str) -> Vec<&str> {
    let bytes = evidence.as_bytes();
    let mut pieces = Vec::new();
    let (mut piece_start, mut index) = (0, 0);
    while index < bytes.len() {
        let dots = bytes[index..].iter().take_while(|byte| **byte == b'.').count();
        let separator = if evidence[index..].starts_with('…') { '…'.len_utf8() }
            else if dots >= 3 { dots }
            else if evidence[index..].starts_with("[...]") { 5 }
            else { 0 };
        if separator > 0 {
            pieces.push(&evidence[piece_start..index]);
            index += separator;
            piece_start = index;
        } else {
            index += evidence[index..].chars().next().map_or(1, char::len_utf8);
        }
    }
    pieces.push(&evidence[piece_start..]);
    pieces
}

/// Tolerant quote lookup. Models often change case, spacing or punctuation in a quote, or join
/// two passages with an ellipsis. Letters and digits must still match the source in order, and
/// the evidence handed to the app is always the exact source substring, never the model's text.
pub fn exact_quote(source: &str, evidence: &str) -> Option<String> {
    if is_blank(evidence) {
        return None;
    }
    if source.contains(evidence) {
        return Some(evidence.to_owned());
    }
    let haystack = fold(source);
    // A repaired quote needs at least four matching letters or digits, a joined passage eight.
    let mut pieces: Vec<Folded> = std::iter::once(evidence).chain(split_ellipsis(evidence)).enumerate()
        .map(|(index, piece)| (index, fold(piece)))
        .filter(|(index, piece)| piece.starts.len() >= if *index == 0 { 4 } else { 8 })
        .map(|(_, piece)| piece).collect();
    pieces.sort_by_key(|piece| std::cmp::Reverse(piece.starts.len()));
    for piece in pieces {
        let Some(byte_index) = haystack.text.find(&piece.text) else { continue };
        let first = haystack.starts.partition_point(|start| *start < byte_index);
        let last = first + piece.starts.len() - 1;
        let quote = &source[haystack.spans[first].0..haystack.spans[last].1];
        if !is_blank(quote) && quote.len() <= 600 {
            return Some(quote.to_owned());
        }
    }
    None
}

type Sources<'a> = Vec<(&'a str, &'a str)>;

fn sources_of<'a>(fragments: impl Iterator<Item = &'a Value>) -> Sources<'a> {
    let mut sources: Sources = Vec::new();
    for fragment in fragments {
        let (Some(id), Some(body)) = (fragment.get("id").and_then(Value::as_str),
            fragment.get("text").and_then(Value::as_str)) else { continue };
        match sources.iter_mut().find(|(known, _)| *known == id) {
            Some(entry) => entry.1 = body,
            None => sources.push((id, body)),
        }
    }
    sources
}

/// Repaired `(sourceIDs, evidence)` with an exact quote, or `None` when nothing grounds the item.
fn ground(item: &Map<String, Value>, sources: &Sources) -> Option<(Vec<String>, String)> {
    let listed = item.get("sourceIDs")?.as_array()?;
    let evidence = item.get("evidence")?.as_str().filter(|evidence| evidence.len() <= 2_400)?;
    let mut ids: Vec<&str> = Vec::new();
    for id in listed.iter().filter_map(Value::as_str) {
        if sources.iter().any(|(known, _)| *known == id) && !ids.contains(&id) {
            ids.push(id);
        }
    }
    ids.truncate(8);
    let owned = |ids: &[&str]| ids.iter().map(|id| (*id).to_owned()).collect::<Vec<_>>();
    for id in &ids {
        let source = sources.iter().find(|(known, _)| known == id)?.1;
        if let Some(quote) = exact_quote(source, evidence) {
            return Some((owned(&ids), quote));
        }
    }
    // The quote may come from a fragment the model forgot to list; the source proves itself.
    for (id, source) in sources {
        if ids.contains(id) || ids.len() >= 8 {
            continue;
        }
        if let Some(quote) = exact_quote(source, evidence) {
            ids.push(id);
            return Some((owned(&ids), quote));
        }
    }
    None
}

fn with_grounding(item: &Map<String, Value>, (source_ids, evidence): (Vec<String>, String)) -> Map<String, Value> {
    let mut repaired = item.clone();
    repaired.insert("sourceIDs".to_owned(), json!(source_ids));
    repaired.insert("evidence".to_owned(), json!(evidence));
    repaired
}

/// The proposed time as given when it is valid, or a local clock time completed with the
/// request's offset. `None` when it is neither.
fn schedule(value: &Value, time_zone: &str) -> Option<Value> {
    if is_scheduled(value) {
        return Some(value.clone());
    }
    with_offset(trim(value.as_str()?), time_zone).map(Value::String)
}

/// One candidate with exact evidence, or `None`. An unusable candidate is dropped, never passed on.
fn clean_candidate(item: &Map<String, Value>, sources: &Sources, time_zone: &str) -> Option<Map<String, Value>> {
    let kind = item.get("kind")?.as_str()?;
    let body = item.get("body")?.as_str()?;
    if !KINDS.contains(&kind) || text(item.get("title"), 240, false).is_none() {
        return None;
    }
    let when = schedule(item.get("scheduledAt")?, time_zone)?;
    let mut cleaned = with_grounding(item, ground(item, sources)?);
    // The app shows the user's own words from the source; an overlong body is not worth the answer.
    cleaned.insert("body".to_owned(), json!(if body.len() <= 2_000 { body } else { "" }));
    cleaned.insert("scheduledAt".to_owned(), when);
    Some(cleaned)
}

const CANDIDATE_KEYS: [&str; 6] = ["kind", "title", "body", "scheduledAt", "sourceIDs", "evidence"];
const CANDIDATE_V2_KEYS: [&str; 7] = ["kind", "title", "body", "scheduledAt", "sourceIDs", "evidence", "replacesID"];

fn shaped<'a>(items: &'a [Value], keys: &[&str]) -> Checked<Vec<&'a Map<String, Value>>> {
    items.iter().map(|item| exact_keys(item, keys).ok_or(Invalid)).collect()
}

struct CheckedAnalysis {
    candidates: Vec<Map<String, Value>>,
    highlights: Vec<Map<String, Value>>,
    uncertainties: Vec<Value>,
}

impl CheckedAnalysis {
    fn into_value(self) -> Value {
        json!({ "candidates": self.candidates, "highlights": self.highlights, "uncertainties": self.uncertainties })
    }
}

/// Validates the shape strictly and each item on its own: an item without a grounded quote,
/// with an invalid date or over a limit is removed, and the rest of the answer is kept. One bad
/// item used to reject the whole answer, which stopped the app's analysis (2026-11-15).
fn check_analysis(candidates: &Value, highlights: &[Value], uncertainties: &Value, sources: &Sources,
    time_zone: &str, everyday: bool, candidate_keys: &[&str]) -> Checked<CheckedAnalysis> {
    let (Some(candidates), Some(uncertainties)) = (candidates.as_array(), uncertainties.as_array()) else { return Err(Invalid) };
    let candidates = shaped(candidates, candidate_keys)?;
    let highlights = shaped(highlights, &["text", "sourceIDs", "evidence"])?;
    Ok(CheckedAnalysis {
        candidates: candidates.into_iter().filter_map(|item| clean_candidate(item, sources, time_zone)).take(6).collect(),
        highlights: if everyday { Vec::new() } else {
            highlights.into_iter().filter_map(|item| {
                text(item.get("text"), 1_500, false)?;
                Some(with_grounding(item, ground(item, sources)?))
            }).take(8).collect()
        },
        uncertainties: uncertainties.iter().filter(|item| text(Some(item), 500, false).is_some()).take(6).cloned().collect(),
    })
}

fn fragments_of<'a>(payload: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> + use<'a> {
    payload.get(key).and_then(Value::as_array).into_iter().flatten()
}

fn time_zone_of(payload: &Value) -> &str {
    payload.get("timeZone").and_then(Value::as_str).unwrap_or("")
}

pub fn validate_analysis_result(value: &Value, payload: &Value) -> Checked<Value> {
    let fields = exact_keys(value, &["candidates", "highlights", "uncertainties"]).ok_or(Invalid)?;
    let highlights = fields["highlights"].as_array().ok_or(Invalid)?;
    let sources = sources_of(fragments_of(payload, "fragments"));
    Ok(check_analysis(&fields["candidates"], highlights, &fields["uncertainties"], &sources,
        time_zone_of(payload), payload.get("mode").is_some_and(|mode| mode == "everyday"), &CANDIDATE_KEYS)?.into_value())
}

pub fn validate_ask_result(value: &Value) -> Checked<Value> {
    let fields = exact_keys(value, &["answer"]).ok_or(Invalid)?;
    text(fields.get("answer"), 16_000, false).ok_or(Invalid)?;
    Ok(value.clone())
}

pub fn validate_lesson_result(value: &Value, payload: &Value) -> Checked<Value> {
    let fields = exact_keys(value, &["candidates", "sections", "uncertainties"]).ok_or(Invalid)?;
    let sections = fields["sections"].as_array().filter(|sections| sections.len() <= 12).ok_or(Invalid)?;
    let sources = sources_of(fragments_of(payload, "fragments"));
    let checked = check_analysis(&fields["candidates"], &[], &fields["uncertainties"], &sources,
        time_zone_of(payload), true, &CANDIDATE_KEYS)?;
    // Sections are the notes themselves: one that cannot be grounded rejects the part, and the
    // app retries or splits it. Homework candidates are extras and are dropped one by one.
    let sections = sections.iter().map(|section| {
        let item = exact_keys(section, &["heading", "body", "sourceIDs", "evidence"]).ok_or(Invalid)?;
        ensure(text(item.get("heading"), 240, false).is_some() && text(item.get("body"), 8_000, false).is_some())?;
        Ok(with_grounding(item, ground(item, &sources).ok_or(Invalid)?))
    }).collect::<Checked<Vec<_>>>()?;
    let candidates: Vec<_> = checked.candidates.into_iter()
        .filter(|item| matches!(item["kind"].as_str(), Some("plan" | "task"))).collect();
    Ok(json!({ "candidates": candidates, "sections": sections, "uncertainties": checked.uncertainties }))
}

pub fn validate_analysis_v2_result(value: &Value, payload: &Value) -> Checked<Value> {
    let fields = exact_keys(value, &["candidates", "highlights", "uncertainties"]).ok_or(Invalid)?;
    let highlights = fields["highlights"].as_array().ok_or(Invalid)?;
    let sources = sources_of(fragments_of(payload, "fragments").chain(fragments_of(payload, "contextFragments")));
    let mut checked = check_analysis(&fields["candidates"], highlights, &fields["uncertainties"], &sources,
        time_zone_of(payload), true, &CANDIDATE_V2_KEYS)?;
    let new_ids: HashSet<&str> = fragments_of(payload, "fragments").filter_map(|fragment| fragment["id"].as_str()).collect();
    let decisions: Vec<&Value> = fragments_of(payload, "priorDecisions").collect();
    let is_open = |decision: &Value| decision["isOpen"] == true;
    let mut replaced = HashSet::new();
    // Each rule below protects a decision the user already made. A candidate that breaks one is
    // dropped; the other candidates in the same answer are unaffected.
    checked.candidates.retain(|candidate| {
        let source_ids: Vec<&str> = candidate["sourceIDs"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
        let replaces = match &candidate["replacesID"] {
            Value::Null => None,
            Value::String(id) if is_uuid(id) => Some(id.to_ascii_lowercase()),
            _ => return false,
        };
        if !source_ids.iter().any(|id| new_ids.contains(id)) {
            return false;
        }
        let linked: Vec<usize> = decisions.iter().enumerate().filter(|(_, decision)| decision["sourceIDs"].as_array()
            .is_some_and(|ids| ids.iter().any(|id| id.as_str().is_some_and(|id| source_ids.contains(&id)))))
            .map(|(index, _)| index).collect();
        // Shared sources cannot identify which event changed. Closed events must never be revived.
        if linked.len() > 1 || linked.iter().any(|index| !is_open(decisions[*index]))
            || (!linked.is_empty() && replaces.is_none()) {
            return false;
        }
        let Some(id) = replaces else { return true };
        let target = decisions.iter().position(|decision| decision["id"].as_str()
            .is_some_and(|known| known.eq_ignore_ascii_case(&id)));
        match target {
            Some(index) if is_open(decisions[index]) && decisions[index]["kind"] == candidate["kind"]
                && linked.first() == Some(&index) => replaced.insert(id),
            _ => false,
        }
    });
    Ok(checked.into_value())
}
