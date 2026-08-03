use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub(crate) enum CanonicalRequestError {
    #[error("request method is required")]
    MissingMethod,
    #[error("request path must be an absolute path")]
    InvalidPath,
    #[error("request timestamp must be non-negative")]
    InvalidTimestamp,
    #[error("request nonce must contain 16 to 128 URL-safe characters")]
    InvalidNonce,
    #[error("request device ID is required")]
    MissingDeviceID,
}

/// Build the exact bytes signed by a native client for an opaque relay request.
///
/// The Worker verifies this same shape. Keeping body hashing and method
/// normalization here prevents each platform binding from inventing a subtly
/// different request string.
pub(crate) fn canonical_device_request(
    method: &str,
    path_with_query: &str,
    body: &[u8],
    timestamp: i64,
    nonce: &str,
    device_id: &str,
) -> Result<String, CanonicalRequestError> {
    if method.trim().is_empty() {
        return Err(CanonicalRequestError::MissingMethod);
    }
    if !path_with_query.starts_with('/') || path_with_query.contains('#') {
        return Err(CanonicalRequestError::InvalidPath);
    }
    if timestamp < 0 {
        return Err(CanonicalRequestError::InvalidTimestamp);
    }
    if !(16..=128).contains(&nonce.len())
        || !nonce
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return Err(CanonicalRequestError::InvalidNonce);
    }
    if device_id.trim().is_empty() {
        return Err(CanonicalRequestError::MissingDeviceID);
    }

    let body_hash = Sha256::digest(body)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();

    Ok(format!(
        "dayflow:v1:{timestamp}:{}:{path_with_query}:{body_hash}:{nonce}:{device_id}",
        method.to_ascii_uppercase()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_request_matches_the_wire_vector() {
        let request = canonical_device_request(
            "post",
            "/v1/sync/events?cursor=abc",
            br#"{"hello":"opaque"}"#,
            1_723_456_789,
            "0123456789abcdef0123456789abcdef",
            "mac-device",
        )
        .unwrap();

        assert_eq!(
            request,
            "dayflow:v1:1723456789:POST:/v1/sync/events?cursor=abc:b7e6d00fedcbdee445a53f6b804273eeb7a62879a6891f7bdc4f9b238675a4f4:0123456789abcdef0123456789abcdef:mac-device"
        );
    }

    #[test]
    fn canonical_request_rejects_invalid_transport_components() {
        assert_eq!(
            canonical_device_request(
                "GET",
                "v1/sync/events",
                &[],
                1,
                "0123456789abcdef",
                "device"
            ),
            Err(CanonicalRequestError::InvalidPath)
        );
        assert_eq!(
            canonical_device_request("GET", "/v1/sync/events", &[], 1, "short", "device"),
            Err(CanonicalRequestError::InvalidNonce)
        );
        assert_eq!(
            canonical_device_request(
                "GET",
                "/v1/sync/events",
                &[],
                -1,
                "0123456789abcdef",
                "device"
            ),
            Err(CanonicalRequestError::InvalidTimestamp)
        );
    }
}
