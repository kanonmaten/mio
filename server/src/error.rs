//! The only error that reaches a client: a fixed status and a fixed code, never free text.

#[derive(Debug, Clone, PartialEq)]
pub struct RequestError {
    pub status: u16,
    pub code: &'static str,
    /// Seconds for `Retry-After`; only sent with status 429.
    pub retry_after: u64,
    /// A wait the provider itself named. Only such a wait may be honoured by the single retry.
    pub provider_retry_after: Option<u64>,
}

impl RequestError {
    pub const fn new(status: u16, code: &'static str) -> Self {
        Self { status, code, retry_after: 60, provider_retry_after: None }
    }

    pub const fn with_retry_after(status: u16, code: &'static str, retry_after: u64) -> Self {
        Self { status, code, retry_after, provider_retry_after: None }
    }
}

impl std::fmt::Display for RequestError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code)
    }
}

impl std::error::Error for RequestError {}
