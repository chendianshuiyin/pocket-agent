use axum::http::{
    HeaderMap,
    header::{AUTHORIZATION, SEC_WEBSOCKET_PROTOCOL},
};
use constant_time_eq::constant_time_eq;

pub const TOKEN_PROTOCOL_PREFIX: &str = "pocket-agent-token.";

pub fn authorized(headers: &HeaderMap, query_token: Option<&str>, expected: &str) -> bool {
    [bearer_token(headers), header_token(headers), query_token]
        .into_iter()
        .flatten()
        .any(|value| constant_time_eq(value.as_bytes(), expected.as_bytes()))
        || websocket_protocol(headers, expected).is_some()
}

pub fn websocket_protocol(headers: &HeaderMap, expected: &str) -> Option<String> {
    let expected_protocol = format!("{TOKEN_PROTOCOL_PREFIX}{}", hex(expected.as_bytes()));
    headers
        .get_all(SEC_WEBSOCKET_PROTOCOL)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .map(str::trim)
        .find(|protocol| constant_time_eq(protocol.as_bytes(), expected_protocol.as_bytes()))
        .map(str::to_owned)
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get(AUTHORIZATION)?.to_str().ok()?;
    let (scheme, token) = value.split_once(' ')?;
    if scheme.eq_ignore_ascii_case("bearer") && !token.is_empty() {
        Some(token)
    } else {
        None
    }
}

fn header_token(headers: &HeaderMap) -> Option<&str> {
    headers.get("x-pocket-agent-token")?.to_str().ok()
}

fn hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

#[cfg(test)]
mod tests {
    use axum::http::{
        HeaderMap, HeaderValue,
        header::{AUTHORIZATION, SEC_WEBSOCKET_PROTOCOL},
    };

    use super::*;

    #[test]
    fn accepts_all_supported_token_transports() {
        let mut bearer = HeaderMap::new();
        bearer.insert(AUTHORIZATION, HeaderValue::from_static("Bearer secret"));
        assert!(authorized(&bearer, None, "secret"));

        let mut custom = HeaderMap::new();
        custom.insert("x-pocket-agent-token", HeaderValue::from_static("secret"));
        assert!(authorized(&custom, None, "secret"));
        assert!(authorized(&HeaderMap::new(), Some("secret"), "secret"));

        let mut protocol = HeaderMap::new();
        protocol.insert(
            SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("chat, pocket-agent-token.736563726574"),
        );
        assert!(authorized(&protocol, None, "secret"));
        assert_eq!(
            websocket_protocol(&protocol, "secret").as_deref(),
            Some("pocket-agent-token.736563726574")
        );
    }

    #[test]
    fn rejects_missing_or_incorrect_tokens() {
        assert!(!authorized(&HeaderMap::new(), None, "secret"));
        assert!(!authorized(&HeaderMap::new(), Some("not-secret"), "secret"));

        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, HeaderValue::from_static("Bearer wrong"));
        assert!(authorized(&headers, Some("secret"), "secret"));
    }
}
