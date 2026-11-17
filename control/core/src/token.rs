//! New tokens for the gateway and Pianissimo, the same shape their installers draw.

use std::io::Read as _;

/// Starts like a provider API key, which the phone refuses (gateway `looks_like_provider_key`).
pub fn looks_like_provider_key(token: &str) -> bool {
    let start = token.get(..4).unwrap_or(token).to_ascii_lowercase();
    ["sk-", "sk_", "gsk_", "aiza"].iter().any(|prefix| start.starts_with(prefix))
}

/// The token shape both services and the phone accept: 32–256 of `A–Z a–z 0–9 _ -`.
pub fn is_service_token(token: &str) -> bool {
    (32..=256).contains(&token.len())
        && token.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        && !looks_like_provider_key(token)
}

/// Base64url without padding, like Python's `secrets.token_urlsafe`.
pub fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut encoded = String::new();
    for group in bytes.chunks(3) {
        let bits = group.iter().fold(0u32, |bits, byte| (bits << 8) | u32::from(*byte)) << (8 * (3 - group.len()));
        for index in 0..=group.len() {
            encoded.push(ALPHABET[(bits >> (18 - 6 * index) & 63) as usize] as char);
        }
    }
    encoded
}

/// 32 random bytes from the kernel as 43 characters; drawn again if it looks like a provider key.
pub fn fresh_token() -> std::io::Result<String> {
    let mut random = std::fs::File::open("/dev/urandom")?;
    loop {
        let mut bytes = [0u8; 32];
        random.read_exact(&mut bytes)?;
        let token = base64url(&bytes);
        if is_service_token(&token) {
            return Ok(token);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_tokens_have_the_installers_shape() {
        let first = fresh_token().unwrap();
        assert_eq!(first.len(), 43);
        assert!(is_service_token(&first));
        assert_ne!(first, fresh_token().unwrap());
    }

    #[test]
    fn provider_shaped_tokens_are_refused() {
        for token in ["gsk_0123456789012345678901234567890123", "SK-0123456789012345678901234567890123", "AIza0123456789012345678901234567890123", "short"] {
            assert!(!is_service_token(token), "{token}");
        }
        assert_eq!(base64url(&[0xfb, 0xff]), "-_8");
    }
}
