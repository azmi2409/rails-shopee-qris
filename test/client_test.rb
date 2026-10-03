# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def setup
    Rails::Shopee::Qris.configure do |config|
      config.token = "B:default_token"
      config.store_id = "12345"
      config.merchant_id = "67890"
      config.phone_number = "+6281234567890"
    end
  end

  def test_matches_whole_idr_amount_inside_payment_window
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")
    now = Time.now

    transaction = {
      transactionId: "TX123456",
      externalTransactionId: "ORD-999",
      amount: "50.000",
      createTime: now.to_i,
      storeId: "12345",
      merchantId: "67890",
      status: 3,
      issuer: "SeaBank"
    }

    result = client.match_transaction(transaction, amount: 50_000, created_at: now - 30, expires_at: now + 300)

    refute_nil result
    assert_equal "TX123456", result[:transaction_id]
    assert_equal "ORD-999", result[:order_id]
    assert_equal "SeaBank", result[:payer_issuer]
    assert_equal 50_000, result[:amount]
    assert_equal now.to_i, result[:transaction_time].to_i
  end

  def test_rejects_minor_unit_cent_amount
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")
    now = Time.now

    # Shopee amounts are NOT cents; 5000000 is 5 million IDR, not 50k
    transaction = {
      transactionId: "TX123456",
      amount: "5.000.000",
      createTime: now.to_i,
      storeId: "12345",
      merchantId: "67890",
      status: 3
    }

    assert_nil client.match_transaction(transaction, amount: 50_000, created_at: now - 30, expires_at: now + 300)
  end

  def test_rejects_non_completed_status
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")
    now = Time.now

    # status 1 is pending, status 2 is failed
    [1, 2, 4, 5].each do |bad_status|
      tx = {
        transactionId: "TX-#{bad_status}",
        amount: "50.000",
        createTime: now.to_i,
        storeId: "12345",
        merchantId: "67890",
        status: bad_status
      }
      assert_nil client.match_transaction(tx, amount: 50_000, created_at: now - 30, expires_at: now + 300)
    end
  end

  def test_rejects_mismatched_store_id
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")
    now = Time.now

    transaction = {
      transactionId: "TX123456",
      amount: "50.000",
      createTime: now.to_i,
      storeId: "99999",
      merchantId: "67890",
      status: 3
    }

    assert_nil client.match_transaction(transaction, amount: 50_000, created_at: now - 30, expires_at: now + 300)
  end

  def test_rejects_transaction_outside_time_window
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")
    now = Time.now

    too_early = {
      transactionId: "TX-EARLY",
      amount: "50.000",
      createTime: (now - 120).to_i,
      storeId: "12345",
      merchantId: "67890",
      status: 3
    }
    assert_nil client.match_transaction(too_early, amount: 50_000, created_at: now, expires_at: now + 300)

    too_late = {
      transactionId: "TX-LATE",
      amount: "50.000",
      createTime: (now + 500).to_i,
      storeId: "12345",
      merchantId: "67890",
      status: 3
    }
    assert_nil client.match_transaction(too_late, amount: 50_000, created_at: now, expires_at: now + 300)
  end

  def test_parses_various_valid_amount_formats
    client = Rails::Shopee::Qris::Client.new(token: "B:token", store_id: "12345")

    assert_equal 50_000, client.parse_amount("50.000")
    assert_equal 409_662, client.parse_amount("409.662")
    assert_equal 50_000, client.parse_amount("50000")
    assert_equal 1_500_000, client.parse_amount("1.500.000")

    assert_nil client.parse_amount("50,000")
    assert_nil client.parse_amount("50.00")
    assert_nil client.parse_amount("-50000")
    assert_nil client.parse_amount("abc")
    assert_nil client.parse_amount(nil)
  end

  def test_transactions_between_paginates_and_normalizes
    client_class = Class.new(Rails::Shopee::Qris::Client) do
      attr_accessor :requests

      def initialize(...)
        @requests = []
        super(...)
      end

      private

      def request(_method, _url, headers:, body: nil)
        @requests << { headers: headers, body: body }
        pos = body.dig(:data, :next_position)

        if pos.to_s.empty?
          {
            code: 0,
            msg: "success",
            data: {
              list: [
                {
                  transactionId: "TX-P1",
                  amount: "15.000",
                  createTime: 1727760100,
                  storeId: "12345",
                  merchantId: "67890",
                  status: 3
                }
              ],
              next_position: "page2_cursor"
            }
          }
        else
          {
            code: 0,
            msg: "success",
            data: {
              list: [
                {
                  transactionId: "TX-P2",
                  amount: "25.000",
                  createTime: 1727760200,
                  storeId: "12345",
                  merchantId: "67890",
                  status: 3
                }
              ],
              next_position: ""
            }
          }
        end
      end
    end

    client = client_class.new(token: "B:test_token", store_id: "12345")
    results = client.transactions_between(start_time: 1727760000, end_time: 1727761000)

    assert_equal 2, results.size
    assert_equal "TX-P1", results[0][:id]
    assert_equal 15_000, results[0][:amount_idr]
    assert_equal "TX-P2", results[1][:id]
    assert_equal 25_000, results[1][:amount_idr]
  end

  def test_list_stores_retries_without_service_list_when_empty
    client_class = Class.new(Rails::Shopee::Qris::Client) do
      attr_reader :call_count

      def initialize(...)
        @call_count = 0
        super(...)
      end

      private

      def request(_method, _url, headers:, body: nil)
        @call_count += 1
        service_list = body.dig(:data, :serviceList)

        if service_list
          # First call with serviceList yields empty
          { code: 0, msg: "success", data: { list: [], storeCount: 0 } }
        else
          # Retry without serviceList yields store
          {
            code: 0,
            msg: "success",
            data: {
              list: [
                { storeId: 9876, storeName: "Cabang Utama", status: 1 }
              ],
              storeCount: 1
            }
          }
        end
      end
    end

    client = client_class.new(token: "B:token")
    stores = client.list_stores

    assert_equal 1, stores.size
    assert_equal "9876", stores.first[:id]
    assert_equal "Cabang Utama", stores.first[:name]
  end


  def test_surfaces_api_error
    client_class = Class.new(Rails::Shopee::Qris::Client) do
      private

      def request(_method, _url, headers:, body: nil)
        { code: 10001, msg: "Parameter error" }
      end
    end

    client = client_class.new(token: "B:token", store_id: "12345")
    error = assert_raises(Rails::Shopee::Qris::Error) do
      client.transactions_between(start_time: 1000, end_time: 2000)
    end

    assert_includes error.message, "Parameter error"
  end
  def test_match_requires_scope_status_id_and_positive_exact_amount
    client = Rails::Shopee::Qris::Client.new
    now = Time.utc(2024, 10, 1)
    valid = { transactionId: "TX", amount: "50.000", createTime: now.to_i,
              storeId: "12345", merchantId: "67890", status: 3 }
    match = ->(tx, amount = 50_000) { client.match_transaction(tx, amount: amount, created_at: now, expires_at: now + 300) }
    assert_equal "TX", match.call(valid)[:transaction_id]
    [{ storeId: nil }, { storeId: {} }, { storeId: "other" },
     { merchantId: nil }, { merchantId: "other" }, { status: 1, completed: true },
     { status: "3", completed: true }, { transactionId: nil, order_id: "ORD" },
     { transactionId: false }, { transactionId: " " }, { amount: 50_000.1 },
     { amount_idr: 50_000.0 }, { amount: "0" }, { createTime: Float::INFINITY },
     { createTime: {} }].each do |change|
      assert_nil match.call(valid.merge(change)), change.inspect
    end
    assert_nil match.call(valid, 50_000.1)
    assert_nil match.call(valid.merge(amount: "0"), 0)
  end

  def test_feed_skips_malformed_and_unscoped_rows_without_hiding_valid_rows
    valid = { transactionId: "TX", amount: "50.000", createTime: 1727740800,
              storeId: "12345", merchantId: "67890", status: 3 }
    rows = [nil, [], valid.merge(transactionId: {}), valid.merge(amount: "invalid"),
            valid.merge(createTime: {}), valid.merge(createTime: Float::NAN),
            valid.merge(storeId: nil), valid.merge(storeId: "other"),
            valid.merge(merchantId: nil), valid.merge(merchantId: "other"), valid, valid]
    client = payment_client([{ code: 0, data: { list: rows, next_position: "" } }])
    result = client.transactions_between(start_time: 1727740000, end_time: 1727750000)
    assert_equal ["TX"], result.map { |tx| tx[:id] }
    assert_equal 50_000, result.first[:amount_idr]
    assert_equal "67890", result.first[:merchant_id]
  end

  def test_feed_rejects_stalled_cursor_and_page_ceiling
    page = { code: 0, data: { list: [], next_position: "same" } }
    assert_raises(Rails::Shopee::Qris::Error) do
      payment_client([page, page]).transactions_between(start_time: 1, end_time: 2)
    end
    assert_raises(Rails::Shopee::Qris::Error) do
      payment_client([page]).transactions_between(start_time: 1, end_time: 2, max_pages: 1)
    end
  end

  def test_store_feed_rejects_stalled_cursor_and_page_ceiling
    page = { code: 0, data: { list: (1..30).map { |id| { storeId: id } }, storeCount: 100 } }
    assert_raises(Rails::Shopee::Qris::Error) { payment_client([page, page]).list_stores }
    assert_raises(Rails::Shopee::Qris::Error) { payment_client([page]).list_stores(max_pages: 1) }
    malformed = { code: 0, data: { list: Array.new(30) { { storeId: false } } } }
    assert_raises(Rails::Shopee::Qris::Error) { payment_client([malformed]).list_stores }
  end

  def test_payment_rejects_malformed_success_envelopes
    [nil, [], { data: {} }, { code: 0 }, { code: 0, data: [] },
     { code: false, data: {} }, { code: 0.0, data: {} }, { code: "0.0", data: {} }].each do |payload|
      assert_raises(Rails::Shopee::Qris::Error) { payment_client([payload]).list_stores }
    end
  end

  def test_session_roundtrip_takes_precedence_over_global_config
    expiry = Time.utc(2030, 1, 1)
    session = JSON.parse(JSON.generate(token: "B:session", store_id: "session-store",
                                      merchant: { id: "session-merchant" }, expires_at: expiry,
                                      switch_credential: { spc_clientid: "session-device" }))
    client = Rails::Shopee::Qris::Client.new(session: session)
    assert_equal "B:session", client.token
    assert_equal "session-store", client.store_id
    assert_equal "session-merchant", client.merchant_id
    assert_equal expiry, client.expires_at
    assert_equal "session-device", client.device_id
    explicit = Rails::Shopee::Qris::Client.new(session: session, token: "B:explicit", store_id: "explicit-store")
    assert_equal "B:explicit", explicit.token
    assert_equal "explicit-store", explicit.store_id
  end

  def test_http_non_success_cannot_return_success_payment_data
    [302, 401, 500].each do |status|
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      worker = Thread.new do
        socket = server.accept
        headers = +""
        headers << socket.read(1) until headers.end_with?("\r\n\r\n")
        socket.read(headers[/Content-Length: (\d+)/i, 1].to_i)
        body = '{"code":0,"data":{"list":[]}}'
        socket.write("HTTP/1.1 #{status} Error\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        socket.close
      end
      klass = Class.new(Rails::Shopee::Qris::Client) do
        define_method(:request) do |method, _url, **options|
          super(method, "http://127.0.0.1:#{port}/", **options)
        end
        private :request
      end
      begin
        error = assert_raises(Rails::Shopee::Qris::Error) { klass.new.list_stores }
        assert_equal status, error.status
        worker.value
      ensure
        server.close
        worker.kill if worker.alive?
      end
    end
  end

  def test_manual_token_session_surfaces_rejection_instead_of_fake_refresh_error
    client = payment_client([{ code: 200020, msg: "NotAuthorized" }])
    client.instance_variable_set(:@token, "B:stale")
    client.instance_variable_set(:@store_id, "123")

    error = assert_raises(Rails::Shopee::Qris::Error) { client.list_stores }

    assert_includes error.message, "rejected the merchant token"
    assert_equal "200020", error.code.to_s
    refute_includes error.message, "cannot be refreshed"
  end

  def test_expiring_session_without_renewal_credentials_does_not_block_feed
    client = payment_client([{ code: 0, data: { list: [], next_position: "" } }])
    client.instance_variable_set(:@token, "B:manual")
    client.instance_variable_set(:@store_id, "123")
    client.instance_variable_set(:@expires_at, Time.now)

    assert_equal [], client.transactions_between(start_time: 1000, end_time: 2000)
  end

  def test_manual_refresh_refusal_leaves_credential_usable
    client = payment_client([{ code: 0, data: { list: [], next_position: "" } }])
    original_token = client.token
    assert_raises(Rails::Shopee::Qris::Error) { client.refresh! }
    assert_equal original_token, client.token
    assert_equal [], client.transactions_between(start_time: 1000, end_time: 2000)
  end
  def test_accepts_outer_jwt_and_extracts_inner_token
    header = Base64.urlsafe_encode64({ alg: "RS256" }.to_json, padding: false)
    payload = Base64.urlsafe_encode64({ userid: "998877", token: "B:extracted_inner", exp: 1877328931 }.to_json, padding: false)
    jwt = "#{header}.#{payload}.signature"

    client = Rails::Shopee::Qris::Client.new(token: jwt)

    assert_equal "B:extracted_inner", client.token
    assert_equal "67890", client.merchant_id
    assert_equal Time.at(1877328931), client.expires_at
  end

  def test_jwt_staff_account_does_not_add_merchant_scope
    Rails::Shopee::Qris.configuration.merchant_id = nil
    payload = Base64.urlsafe_encode64({ userid: "staff-id", token: "B:inner" }.to_json, padding: false)
    client = Rails::Shopee::Qris::Client.new(token: "header.#{payload}.signature")
    assert_nil client.merchant_id
    now = Time.now
    result = client.match_transaction({ id: "TX", amount: 500, create_time: now, store_id: "12345",
                                        merchant_id: "merchant-id", status: 3 },
                                      amount: 500, created_at: now, expires_at: now + 300)
    assert_equal "TX", result[:transaction_id]
  end

  def test_rejects_malformed_jwt_instead_of_using_it_as_payment_token
    ["header.badjson.signature", "header.e30.signature", "header..signature", "not-a-token", 123].each do |token|
      assert_raises(Rails::Shopee::Qris::Error) { Rails::Shopee::Qris::Client.new(token: token) }
    end
  end

  def test_preserves_manual_and_inner_token_bytes
    token = "B:token with\tspace\n"
    assert_equal token, Rails::Shopee::Qris::Client.new(token: token).token
    payload = Base64.urlsafe_encode64({ userid: "staff", token: token }.to_json, padding: false)
    assert_equal token, Rails::Shopee::Qris::Client.new(token: "header.#{payload}.signature").token
  end

  def test_session_normalizes_mixed_keys_without_requiring_all_keys_to_be_strings
    client = Rails::Shopee::Qris::Client.new(session: {
      "token" => "B:session", :store_id => "store", "merchant" => { :id => "merchant", 7 => "extra" },
      :switch_credential => { "spc_clientid" => "device" }
    })
    assert_equal "merchant", client.merchant_id
    assert_equal "device", client.device_id
    assert_equal "extra", client.session[:merchant][7]
  end

  def test_transaction_ranges_reject_invalid_values_before_requesting
    client = payment_client([])
    ["bad", "123bad", "", nil, false, Float::NAN, Float::INFINITY].each do |value|
      assert_raises(Rails::Shopee::Qris::Error) { client.transactions_between(start_time: value, end_time: 100) }
      assert_raises(Rails::Shopee::Qris::Error) { client.transactions_between(start_time: 1, end_time: value) }
    end
    assert_equal [], payment_client([{ code: 0, data: { list: [], next_position: "" } }]).transactions_between(start_time: "08", end_time: "09")
  end

  def test_transaction_detail_rejects_malformed_envelopes
    [{ data: { issuer: "bank" } }, { code: 0, data: [] }, { code: 0.0, data: {} }].each do |payload|
      assert_raises(Rails::Shopee::Qris::Error) { payment_client([payload]).transaction_detail("ORD") }
    end
  end

  def test_malformed_history_is_not_reported_as_empty
    [nil, {}, "bad", 1].each do |list|
      payload = { code: 0, data: { list: list } }
      assert_raises(Rails::Shopee::Qris::Error) do
        payment_client([payload]).transactions_between(start_time: 1, end_time: 2)
      end
      assert_raises(Rails::Shopee::Qris::Error) { payment_client([payload]).list_stores }
    end
  end


  private

  def payment_client(responses)
    klass = Class.new(Rails::Shopee::Qris::Client) do
      define_method(:request) do |_method, _url, headers:, body: nil|
        unless body[:data][:metadata].keys.sort == [:language, :timezone, :token]
          raise Rails::Shopee::Qris::Error, "Payment fields must be siblings of metadata"
        end
        responses.shift
      end
      private :request
    end
    klass.new
  end
end
