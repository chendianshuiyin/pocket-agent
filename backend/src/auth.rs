use axum::http::{HeaderMap, header::AUTHORIZATION};
use constant_time_eq::constant_time_eq;

pub fn authorized(headers: &HeaderMap, query_token: Option<&str>, expected: &str) -> bool {
    let candidate = bearer_token(headers)
        .or_else(|| header_token(headers))
        .or(query_token);

    candidate
        .map(|value| constant_time_eq(value.as_bytes(), expected.as_bytes()))
        .unwrap_or(false)
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

#[cfg(test)]
mod tests {
    use axum::http::{HeaderMap, HeaderValue, header::AUTHORIZATION};

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
    }

    #[test]
    fn rejects_missing_or_incorrect_tokens() {
        assert!(!authorized(&HeaderMap::new(), None, "secret"));
        assert!(!authorized(&HeaderMap::new(), Some("not-secret"), "secret"));
    }
}
