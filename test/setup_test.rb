# frozen_string_literal: true

require_relative "test_helper"

class SetupTest < Minitest::Test
  def setup
    Rails::Shopee::Qris.configure do |config|
      config.phone_number = "+6281234567890"
    end
  end

  def test_normalizes_indonesian_phone_numbers
    setup = Rails::Shopee::Qris::Setup.new

    assert_equal "6281234567890", setup.parse_id_mobile("081234567890")[:e164]
    assert_equal "6281234567890", setup.parse_id_mobile("+62 812-3456-7890")[:e164]
    assert_equal "6281234567890", setup.parse_id_mobile("6281234567890")[:e164]

    assert_raises(Rails::Shopee::Qris::Error) { setup.parse_id_mobile("0211234567") }
    assert_raises(Rails::Shopee::Qris::Error) { setup.parse_id_mobile("12345") }
  end

  def test_formats_phone_for_verification
    setup = Rails::Shopee::Qris::Setup.new

    assert_equal "(+62) 897 7110 640", setup.format_phone_for_verification("628977110640")
    assert_equal "(+62) 812 3456 7890", setup.format_phone_for_verification("6281234567890")
  end

  def test_password_hash_uses_sha256_of_md5
    setup = Rails::Shopee::Qris::Setup.new
    expected = Digest::SHA256.hexdigest(Digest::MD5.hexdigest("secret123"))

    assert_equal expected, setup.hash_shopee_password("secret123")
  end

  def test_request_otp_runs_bootstrap_and_sends_otp
    setup_class = Class.new(Rails::Shopee::Qris::Setup) do
      attr_reader :sent_calls

      def initialize(...)
        @sent_calls = []
        super(...)
      end

      private

      def execute_request(req, uri)
        @sent_calls << { method: req.method, url: uri.to_s, body: req.body }
        case uri.path
        when "/login"
          # Bootstrap
          fake_response(200, "<html></html>", { "set-cookie" => ["SPC_CLIENTID=mock_client_id; Domain=shopee.co.id; Path=/"] })
        when "/v2/shpsec/web/report"
          # Fingerprint
          fake_response(200, { code: 0, data: { riskToken: "risk_token_abc" } }.to_json)
        when "/api/v4/account/business/check_password_migrate"
          fake_response(200, { error: 0, data: {} }.to_json)
        when "/api/v4/account/business/check_account_exist_by_password"
          fake_response(200, { error: 0, data: {} }.to_json)
        when "/api/v4/account/business/authenticate_toc_by_password"
          fake_response(200, { error: 0, data: {} }.to_json)
        when "/api/v4/account/business/get_otp_settings"
          fake_response(200, { error: 0, data: { available_channel_list: [1, 3], default_channel: 3 } }.to_json)
        when "/api/v4/account/business/send_otp"
          fake_response(200, { error: 0, data: {} }.to_json)
        else
          fake_response(200, { error: 0, data: {} }.to_json)
        end
      end

      def fake_response(code, body, headers = {})
        res = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new("1.1", code.to_s, "OK")
        headers.each { |k, v| Array(v).each { |val| res.add_field(k, val) } }
        res.instance_variable_set(:@read, true)
        res.body = body
        res
      end
    end

    setup = setup_class.new
    challenge = setup.request_otp("081234567890", device_report: "captured-browser-report")

    assert_equal 1, challenge[:version]
    assert_equal "6281234567890", challenge[:phone_number]
    assert_equal 3, challenge[:channel]
    assert_equal "risk_token_abc", challenge[:device_fingerprint]
    refute_nil challenge[:cookies]
  end

  def test_verify_otp_authenticates_and_detects_merchants
    setup_class = Class.new(Rails::Shopee::Qris::Setup) do
      private

      def execute_request(_req, uri)
        case uri.path
        when "/api/v4/account/business/verify_otp"
          fake_response(200, { error: 0, data: { otp_token: "tok_123" } }.to_json)
        when "/api/v4/account/business/authenticate_toc_by_otp"
          fake_response(200, { error: 0, data: { toc_nonce: "nonce_abc", toc_account: { userid: 8888 } } }.to_json)
        when "/account/login/auth"
          fake_response(200, "OK")
        when "/nb/mss/mer-detect-api/PartnerMerchantDetectServer/MerchantDetect"
          fake_response(200, {
            errorCode: 0,
            data: {
              selectMerchant: {
                merchantList: [
                  {
                    merchantId: 54321,
                    merchantName: "Toko Shopee Barokah",
                    merchantStatus: 1,
                    staffTobUid: 8888,
                    isActive: true,
                    isBanned: false,
                    isCurrentLoginUser: true
                  }
                ]
              }
            }
          }.to_json)
        else
          fake_response(200, { error: 0, data: {} }.to_json)
        end
      end

      def fake_response(code, body, headers = {})
        res = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new("1.1", code.to_s, "OK")
        headers.each { |k, v| Array(v).each { |val| res.add_field(k, val) } }
        res.instance_variable_set(:@read, true)
        res.body = body
        res
      end
    end

    setup = setup_class.new
    challenge = {
      version: 1,
      phone_number: "6281234567890",
      device_fingerprint: "risk_token_abc",
      cookies: [{ name: "SPC_CLIENTID", value: "spc_123", domain: "shopee.co.id", path: "/" }]
    }

    verification = setup.verify_otp(challenge, "123456")

    assert_equal "nonce_abc", verification[:toc_nonce]
    assert_equal 8888, verification[:toc_userid]
    assert_equal 1, verification[:merchants].size
    assert_equal "54321", verification[:merchants].first[:id]
    assert_equal "Toko Shopee Barokah", verification[:merchants].first[:name]
  end

  def test_complete_login_exchanges_sso_and_mints_token
    token_jwt = make_mock_jwt(token: "B:live_merchant_token", userid: 8888, exp: 1727760000)

    setup_class = Class.new(Rails::Shopee::Qris::Setup) do
      attr_accessor :mock_jwt

      private

      def execute_request(_req, uri)
        case uri.path
        when "/authenticate/login/token/"
          fake_response(200, "OK")
        when "/api/v4/account/business/login_toc"
          fake_response(200, { error: 0, data: { nonce: "auth_code_xyz" } }.to_json)
        when "/account/login/tob/auth"
          # Cookie set by Shopee partner SSO
          cookie = "SPC_CLIENTID=spc_123; Domain=shopee.co.id; Path=/"
          cookie_jwt = "#{Rails::Shopee::Qris::Setup::LIVE_TOKEN_COOKIE}=#{mock_jwt}; Domain=shopee.co.id; Path=/"
          fake_response(200, "OK", { "set-cookie" => [cookie, cookie_jwt] })
        when "/nb/mss/web-api/PartnerAccountServer/GetUserInfo"
          fake_response(200, {
            errorCode: 0,
            data: {
              merchantId: 54321,
              merchantName: "Toko Shopee Barokah",
              store_id: 11111,
              tocUid: "toc_user_1",
              tobUserId: "tob_user_1"
            }
          }.to_json)
        when "/merchant/v1/partner-web/get-store-list"
          fake_response(200, {
            code: 0,
            msg: "success",
            data: {
              list: [
                { storeId: 11111, storeName: "Cabang Utama", status: 1 }
              ],
              storeCount: 1
            }
          }.to_json)
        else
          fake_response(200, { error: 0, data: {} }.to_json)
        end
      end

      def fake_response(code, body, headers = {})
        res = Net::HTTPResponse::CODE_TO_OBJ[code.to_s].new("1.1", code.to_s, "OK")
        headers.each { |k, v| Array(v).each { |val| res.add_field(k, val) } }
        res.instance_variable_set(:@read, true)
        res.body = body
        res
      end
    end

    setup = setup_class.new
    setup.mock_jwt = token_jwt

    verification = {
      version: 1,
      toc_nonce: "nonce_abc",
      toc_userid: 8888,
      spc_clientid: "spc_123",
      device_fingerprint: "risk_abc",
      cookies: [{ name: "SPC_CLIENTID", value: "spc_123", domain: "shopee.co.id", path: "/" }],
      merchants: [
        {
          id: "54321",
          name: "Toko Shopee Barokah",
          staff_user_id: 8888,
          is_active: true,
          is_banned: false,
          is_current_login_user: true
        }
      ]
    }

    fake_client = Object.new
    def fake_client.list_stores
      [{ id: "11111", name: "Cabang Utama", status: 1 }]
    end

    session = setup.complete_login(verification, client: fake_client)

    assert_equal "B:live_merchant_token", session[:token]
    assert_equal "54321", session[:merchant_id]
    assert_equal "Toko Shopee Barokah", session[:merchant_name]
    assert_equal "11111", session[:store_id]
    assert_equal 1, session[:stores].size
    refute_nil session[:switch_credential]
    assert_equal "nonce_abc", session[:switch_credential][:toc_nonce]
  end

  def test_decodes_merchant_credential_jwt
    setup = Rails::Shopee::Qris::Setup.new
    jwt = make_mock_jwt(token: "B:extracted_token", userid: 9999, exp: 1727760000)

    cookies = [
      { name: Rails::Shopee::Qris::Setup::LIVE_TOKEN_COOKIE, value: jwt, domain: "shopee.co.id", path: "/" }
    ]

    credential = setup.read_merchant_credential(cookies)

    assert_equal "B:extracted_token", credential[:token]
    assert_equal "9999", credential[:account_id]
    assert_equal 1727760000000, credential[:expires_at]
  end

  class AuthTransport < Rails::Shopee::Qris::Setup
    attr_accessor :jwt, :profile_id, :failure, :redirect
    attr_reader :requests

    def initialize
      super
      @requests = []
      @profile_id = 54321
    end

    private

    def execute_request(request, uri)
      @requests << [uri, request["Cookie"]]
      raise failure if failure.is_a?(Exception)
      return failure if failure
      return response(302, "", "location" => redirect) if redirect

      case uri.path
      when "/api/v4/account/business/login_status"
        response(200, { error: 0 }.to_json)
      when "/api/v4/account/business/login_toc"
        response(200, { error: 0, data: { nonce: "new-nonce" } }.to_json)
      when "/account/login/tob/auth"
        response(200, "OK", "set-cookie" => "#{LIVE_TOKEN_COOKIE}=#{jwt}; Domain=shopee.co.id; Path=/; Secure")
      when "/nb/mss/web-api/PartnerAccountServer/GetUserInfo"
        response(200, { errorCode: 0, data: { merchantId: profile_id } }.to_json)
      else
        response(200, "OK")
      end
    end

    def response(code, body, headers = {})
      res = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "fixture")
      headers.each { |key, values| Array(values).each { |value| res.add_field(key, value) } }
      res.instance_variable_set(:@read, true)
      res.body = body
      res
    end
  end

  def test_completed_session_survives_json_persistence_and_refresh
    auth = AuthTransport.new
    auth.jwt = make_mock_jwt(token: "B:first", userid: 8888)
    session = auth.complete_login(verification_fixture, client: store_client)
    auth.jwt = make_mock_jwt(token: "B:renewed", userid: 8888)
    renewed = auth.refresh_session(JSON.parse(session.to_json))

    assert_equal "B:renewed", renewed[:token]
    assert_equal "54321", renewed[:merchant][:id]
    assert_equal session[:merchants], renewed[:merchants]
    assert_equal "11111", renewed[:store_id]
  end

  def test_rejects_cross_merchant_token_profile_and_unknown_store
    auth = AuthTransport.new
    auth.jwt = make_mock_jwt(token: "B:other", userid: 9999)
    assert_raises(Rails::Shopee::Qris::Error) { auth.complete_login(verification_fixture, client: store_client) }
    auth.jwt = make_mock_jwt(token: "B:selected", userid: 8888)
    auth.profile_id = 99999
    assert_raises(Rails::Shopee::Qris::Error) { auth.complete_login(verification_fixture, client: store_client) }
    auth.profile_id = 54321
    assert_raises(Rails::Shopee::Qris::Error) { auth.complete_login(verification_fixture, store_id: "unknown", client: store_client) }
  end

  def test_rejects_invalid_versions_and_missing_credentials_before_network
    auth = AuthTransport.new
    assert_raises(Rails::Shopee::Qris::Error) { auth.verify_otp({ version: 2 }, "123456") }
    assert_raises(Rails::Shopee::Qris::Error) { auth.complete_login(verification_fixture.merge(version: 2)) }
    assert_raises(Rails::Shopee::Qris::Error) { auth.refresh_session({ version: 2 }) }
    assert_raises(Rails::Shopee::Qris::Error) { auth.complete_login(verification_fixture.merge(toc_nonce: "")) }
    assert_raises(Rails::Shopee::Qris::Error) { auth.request_otp("081234567890", device_report: "") }
    assert_empty auth.requests
  end

  def test_transport_and_malformed_envelopes_do_not_become_success_or_expiry
    auth = AuthTransport.new
    auth.failure = SocketError.new("offline")
    assert_raises(Rails::Shopee::Qris::Error) { auth.send(:check_account_exists, "6281234567890", nil, "risk") }
    error = assert_raises(Rails::Shopee::Qris::Error) { auth.send(:login_status) }
    assert_nil error.code
    [auth.send(:response, 500, { error: 0, data: {} }.to_json), auth.send(:response, 200, "[]"), auth.send(:response, 200, "not-json"), auth.send(:response, 200, { error: 0, data: [] }.to_json)].each do |bad|
      auth.failure = bad
      assert_raises(Rails::Shopee::Qris::Error) { auth.send(:check_account_exists, "6281234567890", nil, "risk") }
    end
    auth.failure = auth.send(:response, 200, { error: 123, data: {} }.to_json)
    assert_nil auth.send(:check_account_exists, "6281234567890", nil, "risk")
  end

  def test_cookie_scope_duplicates_expiry_deletion_and_restore
    auth = AuthTransport.new
    uri = URI("https://partner.shopee.co.id/account/login")
    response = auth.send(:response, 200, "", "set-cookie" => [
      "sid=root; Domain=shopee.co.id; Path=/; Secure",
      "sid=account; Path=/account; Secure",
      "host=only; Path=/",
      "expired=gone; Max-Age=0; Path=/",
      "old=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/",
      "kept=yes; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=3600; Path=/",
      "foreign=bad; Domain=evil.example; Path=/"
    ])
    auth.send(:update_cookies, response, uri)
    snapshot = JSON.parse(auth.send(:snapshot_cookies).to_json)
    restored = AuthTransport.new
    restored.send(:restore_cookies, snapshot)
    assert_equal "sid=account; sid=root; host=only; kept=yes", restored.send(:build_cookie_header, uri)
    assert_equal "sid=root", restored.send(:build_cookie_header, URI("https://api.partner.shopee.co.id/account/login"))
    assert_equal "host=only; kept=yes", restored.send(:build_cookie_header, URI("http://partner.shopee.co.id/accounting"))
    assert_empty restored.send(:build_cookie_header, URI("https://evil.example/account"))
    deletion = auth.send(:response, 200, "", "set-cookie" => "sid=; Domain=shopee.co.id; Path=/; Max-Age=0")
    restored.send(:update_cookies, deletion, uri)
    assert_equal "sid=account; host=only; kept=yes", restored.send(:build_cookie_header, uri)
  end

  def test_cookie_free_api_does_not_receive_or_mutate_cookies
    auth = AuthTransport.new
    auth.send(:restore_cookies, [{ name: "sid", value: "web", domain: "shopee.co.id", path: "/" }])
    before = auth.send(:snapshot_cookies)
    auth.failure = auth.send(:response, 200, { errorCode: 0, data: {} }.to_json, "set-cookie" => "sid=api; Domain=shopee.co.id; Path=/")
    auth.send(:partner_request, "/test", {})
    assert_nil auth.requests.last[1]
    assert_equal before, auth.send(:snapshot_cookies)
  end

  def test_untrusted_redirects_never_receive_request_or_cookie
    ["https://evil.example/login", "http://partner.shopee.co.id/login", "https://partner.shopee.co.id:8443/login"].each do |target|
      auth = AuthTransport.new
      auth.redirect = target
      auth.send(:restore_cookies, [{ name: "sid", value: "secret", domain: "shopee.co.id", path: "/" }])
      assert_raises(Rails::Shopee::Qris::Error) { auth.send(:follow_get, "https://partner.shopee.co.id/login") }
      assert_equal ["partner.shopee.co.id"], auth.requests.map { |uri, _| uri.host }
    end
    auth = AuthTransport.new
    auth.failure = auth.send(:response, 403, "denied")
    assert_raises(Rails::Shopee::Qris::Error) { auth.send(:follow_get, "https://partner.shopee.co.id/login") }
  end

  private

  def verification_fixture
    {
      version: 1, toc_nonce: "nonce", toc_userid: 8888, spc_clientid: "client", device_fingerprint: "risk", cookies: [],
      merchants: [{ id: "54321", name: "Shop", staff_user_id: 8888, is_active: true, is_banned: false }]
    }
  end

  def store_client
    Object.new.tap do |client|
      def client.list_stores
        [{ id: "11111", name: "Store" }]
      end
    end
  end

  def make_mock_jwt(payload)
    header = Base64.urlsafe_encode64({ alg: "HS256" }.to_json, padding: false)
    data = Base64.urlsafe_encode64(payload.to_json, padding: false)
    "#{header}.#{data}.mock_signature"
  end
end
