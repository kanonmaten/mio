//! The real provider transport: HTTPS only, no redirects, no proxy, no compression.

use std::time::Duration;

use crate::generation::{BoxFuture, Transport, TransportError, UpstreamRequest, UpstreamResponse};

pub struct HttpsTransport {
    client: reqwest::Client,
}

impl HttpsTransport {
    pub fn new() -> Result<Self, TransportError> {
        // The process-wide TLS provider; a second install (tests) is harmless.
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder().https_only(true).redirect(reqwest::redirect::Policy::none())
            .no_proxy().connect_timeout(Duration::from_secs(10)).user_agent(concat!("reqwest/", "0.13"))
            .build().map_err(|_| TransportError)?;
        Ok(Self { client })
    }
}

struct HttpsResponse(reqwest::Response);

impl UpstreamResponse for HttpsResponse {
    fn status(&self) -> u16 {
        self.0.status().as_u16()
    }

    fn header(&self, name: &str) -> Option<String> {
        let values: Vec<&str> = self.0.headers().get_all(name).iter().filter_map(|value| value.to_str().ok()).collect();
        (!values.is_empty()).then(|| values.join(", "))
    }

    fn chunk(&mut self) -> BoxFuture<'_, Result<Option<Vec<u8>>, TransportError>> {
        Box::pin(async move { self.0.chunk().await.map(|chunk| chunk.map(|bytes| bytes.to_vec())).map_err(|_| TransportError) })
    }
}

impl Transport for HttpsTransport {
    fn send(&self, request: UpstreamRequest) -> BoxFuture<'_, Result<Box<dyn UpstreamResponse>, TransportError>> {
        Box::pin(async move {
            let mut builder = self.client.post(&request.url);
            for (name, value) in &request.headers {
                builder = builder.header(*name, value);
            }
            let response = builder.header("Content-Type", "application/json").body(request.body).send().await.map_err(|_| TransportError)?;
            Ok(Box::new(HttpsResponse(response)) as Box<dyn UpstreamResponse>)
        })
    }
}
