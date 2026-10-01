# frozen_string_literal: true

module Rails
  module Shopee
    module Qris
      class Client
        PAY_BASE_URL = "https://shopeepay.shopee.co.id"
        PARTNER_BASE_URL = "https://partner.shopee.co.id"
        TRANSACTIONS_URL = "#{PAY_BASE_URL}/merchant/v1/partner-web/get-transaction-list"
        STORES_URL = "#{PAY_BASE_URL}/merchant/v1/partner-web/get-store-list"
        TRANSACTION_DETAIL_URL = "#{PAY_BASE_URL}/merchant/v1/partner-web/get-transaction-detail"
        USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) Gecko/20100101 Firefox/153.0"
        COMPLETED_STATUS = 3
        STATUS_NAMES = { 1 => "pending", 2 => "failed", 3 => "success", 4 => "refunded", 5 => "expired" }.freeze
        INVALID_TOKEN_CODES = %w[200020 2010000].freeze

        def initialize(
          token: nil,
          store_id: nil,
          merchant_id: nil,
          session: nil,
          phone_number: nil,
          device_id: nil,
          expires_at: nil
        )
          config = Rails::Shopee::Qris.configuration
          raise Error, "Shopee session must be an object" if session && !session.is_a?(Hash)
          @session = session && JSON.parse(JSON.generate(session), symbolize_names: true)
          @token = token || @session&.dig(:token) || config.token
          @store_id = (store_id || @session&.dig(:store_id) || config.store_id)&.to_s
          @merchant_id = (merchant_id || @session&.dig(:merchant, :id) || @session&.dig(:merchant_id) || config.merchant_id)&.to_s
          @phone_number = phone_number || @session&.dig(:phone_number) || config.phone_number
          @device_id = device_id || @session&.dig(:switch_credential, :spc_clientid)
          expiry = expires_at || @session&.dig(:expires_at)
          @expires_at = extract_time(expiry)
          raise Error, "Invalid Shopee session expiry" if expiry && !@expires_at
          @session[:expires_at] = @expires_at if @session && expiry
        end

        attr_reader :token, :store_id, :merchant_id, :session, :phone_number, :device_id, :expires_at
        def create_qris(amount:, reference: nil, static_qris: Rails::Shopee::Qris.configuration.static_qris)
          raise Error, "Shopee static QRIS is not configured" if static_qris.to_s.empty?

          code = Qris.generate(static_qris, amount)
          amount = Integer(amount)
          {
            qris_id: SecureRandom.hex(16),
            qris_code: code,
            amount: amount,
            reference: reference
          }
        rescue ArgumentError, TypeError
          raise Error, "Invalid payment amount"
        end

        def refresh!
          unless session.is_a?(Hash) && session[:switch_credential].is_a?(Hash)
            raise Error, "Shopee session cannot be refreshed without full session credentials; reconnect with OTP"
          end

          updated = Setup.new.refresh_session(session)
          @session = updated
          @token = updated[:token]
          @expires_at = extract_time(updated[:expires_at])
          self
        end

        def transactions_between(start_time:, end_time:, store_id: @store_id, page_size: 10, max_pages: 20)
          refresh! if expires_at && expires_at <= Time.now + 900 && session

          start_ts = start_time.respond_to?(:to_i) ? start_time.to_i : Integer(start_time)
          end_ts = end_time.respond_to?(:to_i) ? end_time.to_i : Integer(end_time)
          raise Error, "Shopee transaction time range is invalid" if start_ts > end_ts

          size = [[1, page_size.to_i].max, 10].min
          pages_limit = [1, max_pages.to_i].max
          want_store = store_id&.to_s
          raise Error, "Shopee store ID is missing" if want_store.to_s.strip.empty?

          all = []
          seen_ids = {}
          seen_cursors = {}
          next_position = ""

          pages_limit.times do
            body = {
              pageSize: size,
              filter: {
                startTime: start_ts,
                endTime: end_ts,
                serviceList: [1, 3]
              },
              sorter: { field: "createTime", order: "descend" },
              next_position: next_position
            }

            resp = request_payment(TRANSACTIONS_URL, body)
            data = Response.data(resp)
            list = data[:list].is_a?(Array) ? data[:list] : []

            list.each do |raw|
              tx = normalize_transaction(raw, want_store)
              next if tx.nil? || seen_ids[tx[:id]]

              seen_ids[tx[:id]] = true
              all << tx
            end

            cursor = data[:next_position]
            raise Error, "Shopee transaction cursor is invalid" unless cursor.nil? || cursor.is_a?(String)
            return all if cursor.to_s.empty?
            raise Error, "Shopee transaction cursor did not advance" if cursor == next_position || seen_cursors[cursor]

            seen_cursors[cursor] = true
            next_position = cursor
          end

          raise Error, "Shopee transaction pagination limit was reached"
        end

        def recent_transactions(minutes: 60, store_id: @store_id)
          now = Time.now
          transactions_between(start_time: now - (minutes * 60), end_time: now, store_id: store_id)
        end

        def transaction_detail(order_sn)
          order_sn = order_sn.to_s.strip
          raise Error, "Shopee transaction_detail needs a non-blank order_sn" if order_sn.empty?

          resp = request_payment(TRANSACTION_DETAIL_URL, { order_sn: order_sn })
          data = Response.data(resp)
          { order_sn: order_sn, issuer: data[:issuer], raw: data }
        end

        def list_stores(max_pages: 10)
          stores = fetch_stores(max_pages, [1, 10])
          return stores if stores && !stores.empty?

          fetch_stores(max_pages, nil) || []
        end

        def match_transaction(transaction, amount:, created_at:, expires_at:, store_id: @store_id)
          return unless transaction.is_a?(Hash)

          return unless transaction[:status].is_a?(Integer) && transaction[:status] == COMPLETED_STATUS

          tx_store = transaction[:store_id] || transaction[:storeId]
          return if store_id.to_s.strip.empty? || scope_id(tx_store) != store_id.to_s
          tx_merchant = transaction[:merchant_id] || transaction[:merchantId]
          return if merchant_id && scope_id(tx_merchant) != merchant_id

          target_amount = parse_amount(amount)
          return unless target_amount && target_amount.positive?
          return unless amount_matches?(transaction, target_amount)

          raw_time = transaction[:create_time] || transaction[:create_time_iso] || transaction[:transaction_time] || transaction[:createTime]
          paid_at = extract_time(raw_time)
          return if paid_at.nil?

          start_window = extract_time(created_at)
          end_window = extract_time(expires_at)
          return unless start_window && end_window && start_window <= end_window
          return if paid_at < start_window - 60 || paid_at > end_window

          id = transaction[:id] || transaction[:transaction_id] || transaction[:transactionId]
          return unless id.is_a?(String) && !id.strip.empty?
          order_id = transaction[:order_id] || transaction[:externalTransactionId] || transaction[:displayTransactionId] || id
          issuer = transaction[:issuer] || transaction[:payer_issuer] || "ShopeePay / QRIS"

          {
            transaction_id: id.strip,
            order_id: order_id.to_s,
            payer_issuer: issuer,
            transaction_time: paid_at,
            amount: target_amount
          }
        rescue ArgumentError, TypeError, RangeError
          nil
        end

        def parse_amount(value)
          return nil if value.nil?

          text = value.to_s.strip
          return nil unless text.match?(/\A\d+\z/) || text.match?(/\A\d{1,3}(?:\.\d{3})+\z/)

          amount = text.delete(".").to_i
          amount.positive? ? amount : nil
        end

        private

        def fetch_stores(max_pages, service_list)
          pages = [1, max_pages.to_i].max
          stores = {}
          seen_cursors = { 0 => true }
          last_store_id = 0

          pages.times do
            body = {
              storeName: "",
              lastStoreId: last_store_id,
              pageSize: 30
            }
            body[:serviceList] = service_list if service_list

            data = Response.data(request_payment(STORES_URL, body))
            list = data[:list].is_a?(Array) ? data[:list] : []

            list.each do |raw|
              store = normalize_store(raw)
              stores[store[:id]] = store if store
            end

            total = data[:storeCount]
            total_reached = total.is_a?(Integer) && total >= 0 && stores.size >= total
            return (stores.values.empty? ? nil : stores.values) if list.empty? || list.size < 30 || total_reached

            last_raw = list.last
            cursor_id = last_raw.is_a?(Hash) ? scope_id(last_raw[:storeId]) : nil
            next_cursor = cursor_id&.match?(/\A\d+\z/) ? cursor_id.to_i : nil
            raise Error, "Shopee store cursor did not advance" if next_cursor.nil? || seen_cursors[next_cursor]

            seen_cursors[next_cursor] = true
            last_store_id = next_cursor
          end

          raise Error, "Shopee store pagination limit was reached"
        end

        def normalize_store(raw)
          return nil unless raw.is_a?(Hash)

          store_id = scope_id(raw[:storeId])
          return nil unless store_id

          {
            id: store_id.to_s,
            name: raw[:storeName].to_s,
            status: raw[:status].is_a?(Integer) ? raw[:status] : 0
          }
        end

        def normalize_transaction(raw, want_store)
          return nil unless raw.is_a?(Hash)

          tx_id = raw[:transactionId] || raw[:id]
          return nil unless tx_id.is_a?(String) && !tx_id.strip.empty?
          tx_id = tx_id.strip

          amount = parse_amount(raw[:amount] || raw[:amount_idr])
          return nil if amount.nil?

          create_time = raw[:createTime] || raw[:create_time]
          return nil unless create_time.is_a?(Numeric) && create_time.finite?
          moment = extract_time(create_time)
          return nil unless moment

          ts = moment.to_i
          tx_store = scope_id(raw[:storeId] || raw[:store_id])
          return nil if tx_store != want_store
          tx_merchant = scope_id(raw[:merchantId] || raw[:merchant_id])
          return nil if merchant_id && tx_merchant != merchant_id

          status = raw[:status].is_a?(Integer) ? raw[:status] : -1
          completed = status == COMPLETED_STATUS
          order_id = raw[:externalTransactionId] || raw[:displayTransactionId] || tx_id
          service = raw[:service] || raw[:transactionType] || "1"

          {
            id: tx_id,
            order_id: order_id.to_s,
            amount_idr: amount,
            create_time: ts,
            create_time_iso: Time.at(ts).utc.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            store_id: tx_store&.to_s,
            merchant_id: tx_merchant,
            status: status,
            status_name: STATUS_NAMES.fetch(status, "unknown_#{status}"),
            completed: completed,
            payment_type: "shopee:#{service}",
            raw: raw
          }
        rescue ArgumentError, TypeError, RangeError
          nil
        end

        def amount_matches?(transaction, target)
          amount = parse_amount(transaction[:amount_idr] || transaction[:amount])
          amount == target
        end

        def scope_id(value)
          return unless value.is_a?(String) || value.is_a?(Integer)

          value = value.to_s.strip
          value unless value.empty?
        end

        def extract_time(value)
          return nil if value.nil?
          return value if value.is_a?(Time)
          return Time.at(value) if value.is_a?(Numeric) && value.finite?
          return nil unless value.is_a?(String) && !value.strip.empty?

          Time.parse(value)
        rescue ArgumentError, TypeError, RangeError
          nil
        end

        def request_payment(url, inner_data, retried: false)
          raise Error, "Shopee merchant token is missing; configure token or login with OTP" if token.to_s.empty?

          payload = {
            data: {
              metadata: {
                token: token,
                language: "id",
                timezone: "Asia/Jakarta"
              },
              **inner_data
            }
          }

          resp = request(:post, url, headers: payment_headers, body: payload)
          raise Error, "Shopee returned a non-object response" unless resp.is_a?(Hash)
          code = resp[:code].to_s

          if (code != "0" && INVALID_TOKEN_CODES.include?(code)) && session && !retried
            refresh!
            return request_payment(url, inner_data, retried: true)
          end

          err = Response.error(resp)
          raise Error.new(err || "ShopeePay request failed", nil, resp[:code], resp) if err
          Response.data(resp)

          resp
        end

        def payment_headers
          {
            "Accept" => "application/json",
            "Accept-Language" => "id,en-US;q=0.9,en;q=0.8",
            "Content-Type" => "application/json",
            "Origin" => PARTNER_BASE_URL,
            "Referer" => "#{PARTNER_BASE_URL}/",
            "User-Agent" => USER_AGENT,
            "X-Timestamp-Ms" => (Time.now.to_f * 1000).to_i.to_s,
            "X-Token" => ""
          }
        end

        def request(method, url, headers:, body: nil)
          uri = URI(url)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 10
          http.read_timeout = 15

          req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
          headers.each { |k, v| req[k] = v }
          req.body = JSON.generate(body) if body

          response = http.request(req)
          parsed = JSON.parse(response.body, symbolize_names: true)

          unless response.code.to_i.between?(200, 299)
            raise Error.new(Response.error(parsed) || "Shopee request failed (HTTP #{response.code})", response.code.to_i, parsed.is_a?(Hash) ? parsed[:code] : nil, parsed)
          end

          parsed
        rescue JSON::ParserError
          raise Error, "Shopee returned an invalid response"
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => error
          raise Error, "Shopee network error: #{error.message}"
        end
      end
    end
  end
end
