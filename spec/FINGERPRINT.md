# Fingerprint Validation

Date: 2026-03-29

## JA4 Capture

Target: `https://tls.peet.ws/api/all`

- Status: `200`
- HTTP version: `h2`
- JA4: `t13d1512h2_8daaf6152771_07d4c546ea27`
- Akamai fingerprint: `1:65536;3:1000;4:6291456;6:262144|15663105|0|m,a,s,p`

Observed request properties:

- 15 cipher suites offered (Chrome 132 minus deprecated 3DES)
- ALPN list: `h2`, `http/1.1`
- Supported groups: `X25519MLKEM768`, `X25519`, `P-256`, `P-384`
- H2 client preface matched expected frame sequence:
  - `SETTINGS`
  - `WINDOW_UPDATE(15663105)`
  - `HEADERS` with pseudo-header order `:method, :authority, :scheme, :path`

## Cloudflare Validation

Validated with AWR using the real BoringSSL fetch path:

1. `https://news.ycombinator.com`
   Status: `200`
   Result: page content returned successfully

2. `https://www.cloudflare.com`
   Status: `200`
   Result: page content returned successfully

This demonstrates that the current AWR binary can perform real HTTPS requests with AWR-owned TLS and load Cloudflare-served content without receiving a challenge page on these targets.
