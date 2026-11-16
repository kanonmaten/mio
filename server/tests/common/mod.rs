//! Shared fixtures: a scripted provider, a gateway on a loopback port and a minimal HTTP client.
#![allow(dead_code)]

use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use mio_gateway::config::Config;
use mio_gateway::generation::{BoxFuture, Transport, TransportError, UpstreamRequest, UpstreamResponse};
use mio_gateway::server::Gateway;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

pub const TOKEN: &str = "fixture_gateway_token_01234567890123456789";
pub const MODEL: &str = "qwen/qwen3.8-27b";

/// What the scripted provider does with one call.
#[derive(Clone)]
pub enum Upstream {
    Reply { status: u16, headers: Vec<(String, String)>, body: Vec<u8> },
    /// A network failure before any response.
    Fail,
    /// Never answers.
    Hang,
    /// Sends headers, then never delivers the body.
    HangBody,
}

impl Upstream {
    pub fn new(status: u16, headers: &[(&str, &str)], body: impl Into<Vec<u8>>) -> Self {
        Self::Reply { status, body: body.into(),
            headers: headers.iter().map(|(name, value)| (name.to_lowercase(), (*value).to_owned())).collect() }
    }

    pub fn json(value: &Value) -> Self {
        Self::new(200, &[("content-type", "application/json")], value.to_string())
    }

    /// A completed chat answer whose content is `content` as compact JSON.
    pub fn completion(content: &Value) -> Self {
        Self::json(&json!({ "choices": [{ "finish_reason": "stop", "message": { "role": "assistant", "content": content.to_string() } }] }))
    }
}

pub struct Call {
    pub url: String,
    pub authorization: String,
    pub body: String,
}

type Script = dyn Fn(usize, &Call) -> Upstream + Send + Sync;

/// Counts how many pending provider calls or unread bodies were dropped (cancelled).
#[derive(Default)]
pub struct Provider {
    pub calls: Mutex<Vec<Call>>,
    pub cancelled: AtomicUsize,
    script: Mutex<Option<Box<Script>>>,
}

impl Provider {
    pub fn new(script: impl Fn(usize, &Call) -> Upstream + Send + Sync + 'static) -> Arc<Self> {
        Arc::new(Self { script: Mutex::new(Some(Box::new(script))), ..Self::default() })
    }

    /// Always the same answer.
    pub fn fixed(reply: Upstream) -> Arc<Self> {
        Self::new(move |_, _| reply.clone())
    }

    pub fn count(&self) -> usize {
        self.calls.lock().unwrap().len()
    }

    pub fn cancelled(&self) -> usize {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub fn body(&self, index: usize) -> Value {
        serde_json::from_str(&self.calls.lock().unwrap()[index].body).unwrap()
    }
}

struct Cancellation(Arc<Provider>, bool);

impl Drop for Cancellation {
    fn drop(&mut self) {
        if !self.1 {
            self.0.cancelled.fetch_add(1, Ordering::SeqCst);
        }
    }
}

struct Scripted {
    status: u16,
    headers: Vec<(String, String)>,
    chunks: VecDeque<Vec<u8>>,
    hang: Option<Cancellation>,
}

impl UpstreamResponse for Scripted {
    fn status(&self) -> u16 {
        self.status
    }

    fn header(&self, name: &str) -> Option<String> {
        self.headers.iter().find(|(known, _)| known == name).map(|(_, value)| value.clone())
    }

    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, TransportError>> {
        Box::pin(async move {
            if self.hang.is_some() {
                std::future::pending::<()>().await;
            }
            Ok(self.chunks.pop_front())
        })
    }
}

/// The provider as the gateway's transport.
pub struct Link(pub Arc<Provider>);

impl Transport for Link {
    fn send(&self, request: UpstreamRequest) -> BoxFuture<'_, Result<Box<dyn UpstreamResponse>, TransportError>> {
        Box::pin(async move {
            let call = Call { url: request.url, authorization: request.authorization, body: request.body };
            let provider = &self.0;
            let index = provider.count();
            let action = (provider.script.lock().unwrap().as_ref().unwrap())(index, &call);
            provider.calls.lock().unwrap().push(call);
            match action {
                Upstream::Fail => Err(TransportError),
                Upstream::Hang => {
                    let _pending = Cancellation(provider.clone(), false);
                    std::future::pending().await
                }
                Upstream::HangBody => Ok(Box::new(Scripted { status: 200, chunks: VecDeque::new(),
                    headers: vec![("content-type".to_owned(), "application/json".to_owned())],
                    hang: Some(Cancellation(provider.clone(), false)) }) as Box<dyn UpstreamResponse>),
                Upstream::Reply { status, headers, body } => Ok(Box::new(Scripted { status, headers, hang: None,
                    // Delivered in pieces, without a content length, as a streamed body would be.
                    chunks: body.chunks(16_384).map(<[u8]>::to_vec).collect() }) as Box<dyn UpstreamResponse>),
            }
        })
    }
}

/// The configuration most tests start from: no per-minute sizing, generous limits, short deadlines.
pub fn config() -> Config {
    Config { api_key: "fixture-upstream-credential".to_owned(), gateway_token: TOKEN.to_owned(), model: MODEL.to_owned(),
        requests_per_minute: 30, requests_per_day: Some(100), upstream_timeout_ms: 1_000, body_timeout_ms: 1_000, ..Config::default() }
}

pub fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> + use<> {
    let pairs: Vec<(String, String)> = pairs.iter().map(|(name, value)| ((*name).to_owned(), (*value).to_owned())).collect();
    move |name| pairs.iter().rev().find(|(known, _)| known == name).map(|(_, value)| value.clone())
}

pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Reply {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(known, _)| known == name).map(|(_, value)| value.as_str())
    }

    pub fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap()
    }

    pub fn error(&self) -> String {
        self.json()["error"].as_str().unwrap_or_default().to_owned()
    }
}

pub struct Server {
    pub address: std::net::SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn start(gateway: Gateway) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    Server { address: listener.local_addr().unwrap(), task: tokio::spawn(gateway.serve(listener)) }
}

pub async fn serve(config: Config, provider: &Arc<Provider>) -> Server {
    start(Gateway::new(config, Arc::new(Link(provider.clone()))).unwrap()).await
}

pub fn authorized() -> Vec<(&'static str, String)> {
    vec![("Authorization", format!("Bearer {TOKEN}")), ("Content-Type", "application/json".to_owned())]
}

fn parse(raw: &[u8]) -> Reply {
    let split = raw.windows(4).position(|window| window == b"\r\n\r\n").expect("a complete response head");
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let mut lines = head.split("\r\n");
    let status = lines.next().unwrap().split(' ').nth(1).unwrap().parse().unwrap();
    let headers = lines.filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.to_lowercase(), value.trim().to_owned())).collect();
    Reply { status, headers, body: String::from_utf8_lossy(&raw[split + 4..]).into_owned() }
}

impl Server {
    pub async fn connect(&self) -> TcpStream {
        TcpStream::connect(self.address).await.unwrap()
    }

    pub async fn request(&self, method: &str, path: &str, headers: &[(&str, String)], body: Option<&[u8]>) -> Reply {
        let mut stream = self.connect().await;
        let mut head = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n");
        for (name, value) in headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        if let Some(body) = body {
            head.push_str(&format!("Content-Length: {}\r\n", body.len()));
        }
        head.push_str("\r\n");
        stream.write_all(head.as_bytes()).await.unwrap();
        // The server may answer and close before a large body has been written.
        let _ = stream.write_all(body.unwrap_or_default()).await;
        read_reply(&mut stream).await
    }

    pub async fn get(&self, path: &str, headers: &[(&str, String)]) -> Reply {
        self.request("GET", path, headers, None).await
    }

    pub async fn post(&self, path: &str, body: &Value) -> Reply {
        self.request("POST", path, &authorized(), Some(body.to_string().as_bytes())).await
    }

    pub async fn post_with(&self, path: &str, body: &Value, extra: &[(&'static str, &str)]) -> Reply {
        let mut headers = authorized();
        for (name, value) in extra {
            headers.retain(|(known, _)| !known.eq_ignore_ascii_case(name));
            headers.push((name, (*value).to_owned()));
        }
        self.request("POST", path, &headers, Some(body.to_string().as_bytes())).await
    }

    pub async fn status_v2(&self) -> Value {
        self.get("/v2/status", &authorized()).await.json()
    }
}

pub async fn read_reply(stream: &mut TcpStream) -> Reply {
    let mut raw = Vec::new();
    let _ = stream.read_to_end(&mut raw).await;
    parse(&raw)
}

/// `base` with the top-level fields of `patch` replaced or added.
pub fn with(base: &Value, patch: Value) -> Value {
    let mut merged = base.clone();
    merged.as_object_mut().unwrap().extend(patch.as_object().unwrap().clone());
    merged
}

/// `base` without one top-level field.
pub fn without(base: &Value, key: &str) -> Value {
    let mut reduced = base.clone();
    reduced.as_object_mut().unwrap().shift_remove(key);
    reduced
}

/// A counter store that counts every save and can be made to fail.
#[derive(Default)]
pub struct CountingStore {
    pub saves: AtomicUsize,
    pub failing: bool,
    inner: mio_gateway::state_store::MemoryCounterStore,
}

impl CountingStore {
    pub fn failing() -> Self {
        Self { failing: true, ..Self::default() }
    }
}

impl mio_gateway::state_store::CounterStore for CountingStore {
    fn load(&self) -> mio_gateway::state_store::Counters {
        self.inner.load()
    }

    fn save(&self, counters: &mio_gateway::state_store::Counters) -> Result<(), mio_gateway::state_store::StoreError> {
        self.saves.fetch_add(1, Ordering::SeqCst);
        if self.failing { Err(mio_gateway::state_store::StoreError) } else { self.inner.save(counters) }
    }
}
