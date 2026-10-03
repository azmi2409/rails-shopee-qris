# Changelog

## 0.2.1

- Do not infer merchant ID from JWT staff `userid`.
- Reject malformed credentials, invalid payment envelopes, and invalid time ranges.
- Do not suppress unknown password-auth failures or captcha requirements.
- Preserve provider rejection codes without claiming an undocumented expiry reason.
- Expose optional OTP `seed` as opaque response data, not delivery evidence.
- Reject malformed transaction/store lists rather than returning misleading empty history.
- Preserve selected merchant scope when constructing the OTP data client.
- Reject fractional provider result codes and malformed OTP channel settings.
- Correct prior verification claims: no successful OTP login or payment settlement observed.

## 0.2.0

Observed store listing and an empty transaction feed with a merchant token. OTP
requests returned success without recipient-confirmed delivery. Transaction detail,
successful OTP login and payment settlement were not verified live.

### Added
- `Client` accepts either the raw `B:...` merchant token or the whole
  `__shopee_partner_website_x_token_live` JWT cookie, extracting the inner token
  and advisory expiry.
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
- **`10002` compatibility.** Empty-password responses were allowed to continue to the
  OTP step. Its meaning was not independently established.
- **Wrong refresh error.** A rejected manual token raised "session cannot be refreshed";
  it now reports the real rejection and its code. Proactive refresh only runs when the
  session actually has renewal credentials.
- **Duplicate-key crash.** `Client` symbolized sessions via `JSON.generate`, which raised
  on hashes carrying both `"token"` and `:token`.
- **`48401003`** is reported as OTP rejection rather than a bare code; reason unspecified.
- QRIS generation rejects fractional and oversized amounts instead of truncating them,
  and parsing rejects non-decimal lengths and duplicate tags.

## 0.1.0

Initial release: dynamic QRIS generation, static QRIS validation, CRC-16, store listing,
transaction feed, payment matching, OTP login flow.
