# Changelog

## 0.2.0

Verified against a live ShopeePay Partner merchant account (store listing, transaction
feed, transaction detail, device-risk, OTP request).

### Added
- `Client` accepts either the raw `B:...` merchant token or the whole
  `__shopee_partner_website_x_token_live` JWT cookie, extracting the inner token,
  `userid` and `exp`.
- `Client#refreshable?` tells callers whether a session can silently renew.
- Provider error codes are translated into actionable text
  (`10002`, `200020`, `2010000`, `48401003`, `48401102`, `48401103`, `48500102`).
- `Setup` exposes `CHANNEL_NAMES`; unavailable OTP channels are reported with the
  available list.
- `test/response_test.rb` coverage for the error mapping.

### Fixed
- **Payment envelope shape.** Request fields were nested under `data.metadata`; Shopee
  expects them as siblings of `metadata`. Store listing and the transaction feed never
  worked before this.
- **`10002` aborted every non-password account.** It means "no password set" — the OTP
  flow now continues instead of raising.
- **Wrong refresh error.** A rejected manual token raised "session cannot be refreshed";
  it now reports the real rejection and its code. Proactive refresh only runs when the
  session actually has renewal credentials.
- **Duplicate-key crash.** `Client` symbolized sessions via `JSON.generate`, which raised
  on hashes carrying both `"token"` and `:token`.
- **`48401003`** is now reported as a wrong/expired OTP rather than a bare code.
- QRIS generation rejects fractional and oversized amounts instead of truncating them,
  and parsing rejects non-decimal lengths and duplicate tags.

## 0.1.0

Initial release: dynamic QRIS generation, static QRIS validation, CRC-16, store listing,
transaction feed, payment matching, OTP login flow.
