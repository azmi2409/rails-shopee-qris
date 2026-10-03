# rails-shopee-qris

Unofficial Ruby/Rails ShopeePay Partner client, based on `QrisMerchantID` Shopee API logic and `rails-gopay-unofficial` gem structure. Ruby >= 3.1; no runtime dependencies beyond stdlib.

Use only with merchant authorization. Internal Shopee APIs can change. Store listing and an empty transaction feed were observed with a merchant token. OTP endpoints accepted requests, but recipients reported no delivery; successful OTP login and money settlement remain unverified. Never log tokens, passwords, device reports, session cookies, or raw payment data.

## Installation

Install published version from RubyGems:

```ruby
gem "rails-shopee-qris", "~> 0.2.0"
```

Version 0.2.1 contains the reviewed validation and merchant-scope fixes; it must be published before RubyGems consumers can install it. To exercise this checkout locally, use `gem "rails-shopee-qris", path: "../rails-shopee-qris"`.

```ruby
require "rails/shopee/qris"

Rails::Shopee::Qris.configure do |config|
  config.static_qris = Rails.application.credentials.dig(:shopee, :static_qris)
  config.phone_number = Rails.application.credentials.dig(:shopee, :phone_number)
  config.device_report = Rails.application.credentials.dig(:shopee, :device_report)
end
```

## Direct merchant token

Pass either the inner `B:...` token or the whole `__shopee_partner_website_x_token_live` cookie value. Client extracts the inner token and advisory expiry. JWT `userid` is a staff account ID, **not** merchant ID; provide merchant scope explicitly when known. JWT decoding does not verify its signature; Shopee validates credentials on each request.

Get a fresh token: log in at `partner.shopee.co.id` → DevTools → Network → open the ShopeePay transaction history page → click `get-transaction-list` → Request Payload → `data.metadata.token`.

```ruby
client = Rails::Shopee::Qris::Client.new(
  token: "B:...", store_id: "12345", merchant_id: "67890"
)
stores = client.list_stores
```

Tokens rotate when the portal session refreshes; `200020` means paste a new one. A manually supplied token cannot silently renew — only an OTP session carries `switch_credential` and can call `refresh!`.

## OTP login

Shopee device-risk telemetry must come from your own authenticated browser's request to `https://df.infra.sz.shopee.co.id/v2/shpsec/web/report`. Supply the captured request body as `device_report`; an empty report can result in silently suppressed OTP delivery. Password required for password-protected accounts. Captcha challenges need browser resolution; library does not bypass them.

```ruby
setup = Rails::Shopee::Qris::Setup.new
challenge = setup.request_otp(
  "081234567890", password: "account password", channel: 3,
  device_report: Rails.application.credentials.dig(:shopee, :device_report)
)
# Encrypt/persist entire challenge between requests.
outcome = setup.login_with_otp(challenge, "123456")

if outcome[:status] == "merchant-selection-required"
  verification = outcome[:verification]
  merchant_id = outcome[:merchants].find { |m| m[:is_active] && !m[:is_banned] }.fetch(:id)
  # In production, let merchant choose instead of taking first available.
  shopee_session = setup.complete_login(verification, merchant_id: merchant_id)
else
  shopee_session = outcome.fetch(:session)
end
```

Channels: `1` SMS, `2` voice, `3` WhatsApp, `4` email, `5` Zalo. Omit `channel:` to use the channel Shopee recommends for that account; asking for an unavailable one raises with the available list. `verify_otp(challenge, otp)` also returns verification separately, reusable by `complete_login(verification, merchant_id:, store_id:)`. Requested store must belong to selected merchant; multiple stores can leave `store_id` unset, requiring explicit selection before transaction reconciliation.

Persist **entire** session encrypted, including `cookies`, `merchant`, `merchants`, and `switch_credential`. These are credentials, not safe client-side session data.

OTP request success and optional `seed` do not prove SMS/WhatsApp delivery. `device_report` means the raw browser SDK report request body, not the `riskToken` returned by its response. No reliable report-format or delivery-status check is available here. Do not retry repeatedly or switch channels without merchant consent.

Rails cookie sessions cannot hold full Shopee state (4 KB limit). Use server-side sessions; memory-backed development sessions disappear on restart. Never persist passwords for resend—prompt again when required.

```ruby
serialized = JSON.generate(shopee_session)
restored = JSON.parse(serialized, symbolize_names: true)
client = Rails::Shopee::Qris::Client.new(session: restored)
client.refresh! # Account session must still be alive; otherwise new OTP needed.
restored = client.session # Persist after renewal.
```

Session hashes use symbol keys. Parse stored JSON with `symbolize_names: true`. Expiry is advisory; provider login-status determines account session validity.

## Dynamic QRIS

```ruby
payment = client.create_qris(amount: 50_321, reference: "ORDER-1002")
# { qris_id:, qris_code:, amount:, reference: }
```

Static payload must have valid CRC, Indonesian country tag, merchant tag, and static initiation tag `01=11`. Generation sets `01=12`, injects whole-rupiah tag `54`, recalculates CRC-16/CCITT-FALSE. Amount must be positive integer or digit-only string; fractional amounts are rejected, never truncated. QR rendering is caller-owned (for example `rqrcode`).

`qris_id` and `reference` are local metadata, not provider-created order IDs and not transmitted in QRIS. Amount-only reconciliation cannot distinguish simultaneous equal-amount invoices. Assign distinct amounts/time windows, exclude already-consumed transaction IDs, and enforce DB uniqueness/atomic settlement in application.

```ruby
qris = Rails::Shopee::Qris::Qris
qris.valid_static?(static_payload)
qris.parse(static_payload)
qris.generate(static_payload, 75_000)
qris.crc16("123456789") # "29B1"
```

## Transactions and reconciliation

```ruby
transactions = client.transactions_between(
  start_time: invoice.created_at - 60, end_time: Time.now
)
matched = transactions.filter_map do |transaction|
  client.match_transaction(
    transaction, amount: invoice.amount,
    created_at: invoice.created_at, expires_at: invoice.expires_at
  )
end.first
```

Wire amounts are whole rupiah: `"409.662"` means `409662`, **not cents**. Feed requests use epoch seconds, services `[1, 3]`, page size at most 10. Rows must have proven store scope and configured merchant scope. Only numeric status `3` completes payment; missing ID/scope, malformed amount/time, wrong status, or out-of-window payment cannot match. Window is `[created_at - 60 seconds, expires_at]`.

Cursor cycles and pagination ceilings raise `Rails::Shopee::Qris::Error`, rather than silently treating incomplete history as complete. Defaults: 20 transaction pages, 10 store pages; increase `max_pages` when needed. Store discovery retries without service filter only when filtered result is empty.

Issuer comes from detail endpoint, not transaction feed:

```ruby
transaction = transactions.first
order_sn = transaction.fetch(:raw)[:displayTransactionId] || transaction.fetch(:id)
detail = client.transaction_detail(order_sn)
issuer = detail[:issuer]
```

Persist `client.session` if token renews during polling. Background jobs, scheduling, transaction deduplication, and invoice settlement remain caller-owned.

## Errors

```ruby
begin
  client.list_stores
rescue Rails::Shopee::Qris::Error => error
  # Inspect error.status / error.code. Do not log error.payload (may contain credentials).
end
```

Invalid provider envelopes, HTTP failures, expired credentials, malformed inputs, and incomplete pagination fail explicitly. Shopee often answers with a bare numeric code and no message; observed codes are translated:

| Code | Meaning |
| --- | --- |
| `10002` | Undocumented password-auth response; empty-password probe may continue to OTP, but it does not prove account existence or password state |
| `200020` | Token invalid or expired — paste a fresh one |
| `2010000` | Request carried no token |
| `48401003` | Credential rejected; when returned by OTP verification, the OTP was rejected (reason unspecified) |
| `48401102` | Password required before an OTP is sent |
| `48401103` | OTP channel unavailable for this account |
| `48500102` | Account session expired; log in again with an OTP |

## Verification

```sh
ruby -Ilib:test -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'
gem build rails-shopee-qris.gemspec
```

## RubyGems release

Package with `gem build rails-shopee-qris.gemspec`. Authenticate via `gem signin` (or configure a scoped `GEM_HOST_API_KEY` with push permission), then:

```sh
gem push rails-shopee-qris-0.2.1.gem --host https://rubygems.org
```

RubyGems versions are immutable. Bump the gemspec version before subsequent releases. Built `.gem` files and credentials must not be committed.

MIT license; see [LICENSE.txt](LICENSE.txt).
