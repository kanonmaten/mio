//! Each task owns its prompt, schema, answer budget and validator. Wire parsing never
//! substitutes for the task's independent grounded-domain validator.

use serde_json::Value;

use crate::adapters::{Generation, Message, Policy};
use crate::analysis;
use crate::prompts;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mode {
    Ask,
    Analyze,
    AnalyzeV2,
    Lesson,
    /// `/v2/lesson-notes`: exam hints, speaker roles and a subject suggestion.
    LessonV2,
}

impl Mode {
    pub fn parse(mode: &str) -> Option<Self> {
        match mode {
            "ask" => Some(Self::Ask),
            "analyze" => Some(Self::Analyze),
            "analyze-v2" => Some(Self::AnalyzeV2),
            "lesson" => Some(Self::Lesson),
            "lesson-v2" => Some(Self::LessonV2),
            _ => None,
        }
    }

    /// The task whose profile, quota floor and capabilities apply.
    pub const fn task_id(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Lesson | Self::LessonV2 => "lesson",
            Self::Analyze | Self::AnalyzeV2 => "everyday",
        }
    }

    /// The fixed public code for an answer that fails this task's validator.
    pub const fn result_error(self) -> &'static str {
        match self {
            Self::Ask => "invalid_upstream_answer",
            Self::Lesson | Self::LessonV2 => "invalid_lesson_result",
            Self::Analyze | Self::AnalyzeV2 => "invalid_analysis_result",
        }
    }
}

/// Output limits are reservations against the provider's per-minute token budget, so they stay
/// close to what each task writes: a short answer, at most six bodiless candidates, or lesson notes.
pub fn create_task_request(mode: Mode, payload: &Value) -> Generation {
    let (system, format, limit, version) = match mode {
        Mode::Ask => (prompts::ASK_SYSTEM.to_owned(), analysis::ask_format(), 1_200, prompts::PROMPT_VERSION),
        Mode::Analyze => (prompts::ANALYSIS_SYSTEM.to_owned(), analysis::analysis_format(), 1_500, prompts::PROMPT_VERSION),
        Mode::AnalyzeV2 => (prompts::analysis_v2_system(), analysis::analysis_v2_format(), 1_500, prompts::ANALYSIS_V2_PROMPT_VERSION),
        Mode::Lesson => (prompts::LESSON_SYSTEM.to_owned(), analysis::lesson_format(), 3_000, prompts::PROMPT_VERSION),
        // Up to eight short exam hints on top of v1's notes.
        Mode::LessonV2 => (prompts::lesson_v2_system(), analysis::lesson_v2_format(), 3_500, prompts::LESSON_V2_PROMPT_VERSION),
    };
    Generation {
        messages: vec![Message { role: "system".to_owned(), content: system },
            // The approved payload, byte for byte as compact JSON in the app's key order.
            Message { role: "user".to_owned(), content: payload.to_string() }],
        structured_output: format, max_output_tokens: limit, policy: Policy::default(), prompt_version: version,
    }
}

pub fn validate_task_result(mode: Mode, text: &str, payload: &Value) -> Result<Value, &'static str> {
    let value: Value = serde_json::from_str(text).map_err(|_| mode.result_error())?;
    match mode {
        Mode::Ask => analysis::validate_ask_result(&value),
        Mode::Analyze => analysis::validate_analysis_result(&value, payload),
        Mode::AnalyzeV2 => analysis::validate_analysis_v2_result(&value, payload),
        Mode::Lesson => analysis::validate_lesson_result(&value, payload),
        Mode::LessonV2 => analysis::validate_lesson_v2_result(&value, payload),
    }.map_err(|_| mode.result_error())
}
