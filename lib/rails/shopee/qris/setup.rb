# frozen_string_literal: true

module Rails
  module Shopee
    module Qris
      class Setup
        ACCOUNT_BASE_URL = "https://partner.business.accounts.shopee.co.id"
        PARTNER_BASE_URL = "https://partner.shopee.co.id"
        PARTNER_API_BASE_URL = "https://api.partner.shopee.co.id"
        DEVICE_FINGERPRINT_REPORT_URL = "https://df.infra.sz.shopee.co.id/v2/shpsec/web/report"
        SZ_SDK_VERSION = "1.12.26-user.1"

        ACCOUNT_CLIENT_ID = "5"
        BUSINESS_CLIENT_ID = "1"
        PARTNER_LOGIN_FROM = "12"

        OTP_OPERATION = 50001
        OTP_CHANNELS = [1, 2, 3, 5].freeze
        SEND_OTP_CHANNELS = [1, 2, 3, 5, 4].freeze
        DEFAULT_OTP_CHANNEL = 3
        CHANNEL_NAMES = { 1 => "SMS", 2 => "voice", 3 => "WhatsApp", 4 => "email", 5 => "Zalo" }.freeze
        NEED_OTP_CODE = 48401102
        NOT_LOGIN_CODE = 48500102
        EMPTY_PASSWORD_CONTINUATION_CODE = 10002
        OTP_CHANNEL_UNAVAILABLE_CODE = 48401103
        OTP_REJECTED_CODE = 48401003
        PASSWORD_REQUIRED = "This Shopee account is password-protected; supply the password to receive an OTP"

        LIVE_TOKEN_COOKIE = "__shopee_partner_website_x_token_live"
        CLIENT_ID_COOKIE = "SPC_CLIENTID"
        CSRF_COOKIE = "csrftoken"

        def initialize
          @cookies = {}
        end

        attr_reader :cookies

        def request_otp(phone_number = Rails::Shopee::Qris.configuration.phone_number, password: nil, channel: nil, device_report: Rails::Shopee::Qris.configuration.device_report)
          phone_info = parse_id_mobile(phone_number)
          raise Error, "Supply a captured Shopee device report to request an OTP" unless device_report.is_a?(String) && !device_report.strip.empty?
          if !channel.nil? && (!channel.is_a?(Integer) || !SEND_OTP_CHANNELS.include?(channel))
            raise Error, "Invalid Shopee OTP channel"
          end
          phone = phone_info[:e164]
          @cookies.clear

          bootstrap
          fingerprint = device_fingerprint(device_report)

          account_request("/api/v4/account/business/check_password_migrate", { phone: phone }, fingerprint)
          check_account_exists(phone, password, fingerprint)
          has_password = authenticate_by_password(phone, password, fingerprint)

          settings = account_request(
            "/api/v4/account/business/get_otp_settings",
            {
              operation: OTP_OPERATION,
              phone: phone,
              security_device_fingerprint: fingerprint,
              support_session: false,
              supported_channels: OTP_CHANNELS
            },
            fingerprint
          )

          available = settings[:available_channel_list].nil? ? [] : settings[:available_channel_list]
          unless available.is_a?(Array) && available.all? { |c| c.is_a?(Integer) && SEND_OTP_CHANNELS.include?(c) }
            raise Error, "Shopee returned invalid available OTP channels"
          end
          default_ch = settings[:default_channel]
          resolved = channel || default_ch || DEFAULT_OTP_CHANNEL
          unless resolved.is_a?(Integer) && SEND_OTP_CHANNELS.include?(resolved)
            raise Error, "Shopee returned an invalid OTP channel"
          end
          if !available.empty? && !available.include?(resolved)
            names = available.map { |c| "#{c} (#{CHANNEL_NAMES[c] || 'unknown'})" }.join(", ")
            raise Error, "Shopee OTP channel #{resolved} is unavailable for this account; available: #{names}"
          end

          sent = begin
            account_request(
              "/api/v4/account/business/send_otp",
              {
                operation: OTP_OPERATION,
                phone: phone,
                security_device_fingerprint: fingerprint,
                support_session: false,
                supported_channels: SEND_OTP_CHANNELS,
                channel: resolved,
                captcha_signature: ""
              },
              fingerprint
            )
          rescue Error => e
            raise Error.new(
              e.code == OTP_CHANNEL_UNAVAILABLE_CODE ?
                "Shopee refused OTP at /api/v4/account/business/send_otp on channel #{resolved}; choose another available channel" :
                e.message,
              e.status, e.code, e.payload
            )
          end

          {
            version: 1,
            phone_number: phone,
            channel: resolved,
            available_channels: available,
            device_fingerprint: fingerprint,
            risk_token: fingerprint,
            has_password: has_password,
            cookies: snapshot_cookies,
            # Opaque provider field; neither its meaning nor OTP delivery is established.
            seed: sent[:seed],
            requested_at: (Time.now.to_f * 1000).to_i
          }
        end

        def verify_otp(challenge, otp)
          challenge = symbolize_state(challenge)
          validate_version(challenge, "OTP challenge")
          validate_strings(challenge, :device_fingerprint, :phone_number)
          phone = parse_id_mobile(challenge[:phone_number])[:e164]
          code = otp.to_s.strip

          unless code.to_s.match?(/\A\d{4,10}\z/)
            raise Error, "Shopee OTP must contain 4 to 10 digits"
          end

          restore_cookies(challenge[:cookies] || [])
          fingerprint = challenge[:device_fingerprint].to_s

          formatted_phone = format_phone_for_verification(phone)
          begin
            verified = account_request(
              "/api/v4/account/business/verify_otp",
              {
                operation: OTP_OPERATION,
                otp: code.to_s,
                phone: formatted_phone,
                security_device_fingerprint: fingerprint,
                support_session: false
              },
              fingerprint
            )
          rescue Error => e
            raise e unless e.code.to_s == OTP_REJECTED_CODE.to_s

            raise Error.new(
              "Shopee rejected the OTP at /api/v4/account/business/verify_otp; cause is not established",
              e.status, e.code, e.payload
            )
          end

          token = verified[:otp_token]
          raise Error, "Shopee OTP verification returned no token" unless token.is_a?(String) && !token.empty?

          authenticated = account_request(
            "/api/v4/account/business/authenticate_toc_by_otp",
            {
              otp_token: token,
              security_device_fingerprint: fingerprint,
              is_signup: false
            },
            fingerprint
          )

          toc_nonce = authenticated[:toc_nonce]
          toc_account = authenticated[:toc_account]
          toc_userid = toc_account.is_a?(Hash) ? toc_account[:userid] : nil
          if !toc_nonce.is_a?(String) || toc_nonce.empty? || !toc_userid.is_a?(Integer) || toc_userid <= 0
            raise Error, "Shopee OTP authentication returned an incomplete account session"
          end

          spc_clientid = jar_get(CLIENT_ID_COOKIE, ACCOUNT_BASE_URL)
          raise Error, "Shopee authentication returned no client session id" if spc_clientid.to_s.empty?

          login_url = "#{PARTNER_BASE_URL}/account/login/auth?lang=id" \
                      "&spc_clientid=#{URI.encode_www_form_component(spc_clientid)}" \
                      "&state=#{URI.encode_www_form_component(partner_state)}" \
                      "&toc_nonce=#{URI.encode_www_form_component(toc_nonce.to_s)}"
          follow_get(login_url)

          detected = partner_request("/nb/mss/mer-detect-api/PartnerMerchantDetectServer/MerchantDetect", {}, toc_nonce: toc_nonce.to_s)
          select_merchant = detected[:selectMerchant]
          raw_list = select_merchant.is_a?(Hash) && select_merchant[:merchantList].is_a?(Array) ? select_merchant[:merchantList] : []
          merchants = raw_list.filter_map { |raw| normalize_merchant(raw) }

          raise Error, "The Shopee account has no accessible merchant" if merchants.empty?

          {
            version: 1,
            toc_nonce: toc_nonce,
            toc_userid: toc_userid,
            spc_clientid: spc_clientid,
            device_fingerprint: fingerprint,
            cookies: snapshot_cookies,
            merchants: merchants,
            verified_at: (Time.now.to_f * 1000).to_i
          }
        end

        def complete_login(verification, merchant_id: nil, store_id: nil, client: nil)
          verification = symbolize_state(verification)
          validate_version(verification, "OTP verification")
          validate_strings(verification, :toc_nonce, :spc_clientid, :device_fingerprint)
          raise Error, "Shopee verification has no account id" unless verification[:toc_userid].is_a?(Integer) && verification[:toc_userid] > 0
          restore_cookies(verification[:cookies] || [])
          merchant, credential = complete_base(verification, merchant_id)
          profile = get_profile(credential[:token], merchant[:id])

          data_client = client || Client.new(token: credential[:token], merchant_id: merchant[:id])
          stores = data_client.list_stores
          chosen_store = choose_store_id(stores, store_id, profile[:store_id])

          {
            version: 1,
            token: credential[:token],
            merchant_id: merchant[:id],
            merchant_name: merchant[:name].to_s.empty? ? profile[:merchant_name] : merchant[:name],
            store_id: chosen_store,
            stores: stores,
            account_id: credential[:account_id],
            merchant: merchant.merge(name: merchant[:name].to_s.empty? ? profile[:merchant_name] : merchant[:name]),
            merchants: verification[:merchants].map(&:dup),
            cookies: snapshot_cookies,
            switch_credential: {
              toc_nonce: verification[:toc_nonce],
              spc_clientid: verification[:spc_clientid],
              device_fingerprint: verification[:device_fingerprint]
            },
            profile: profile,
            created_at: (Time.now.to_f * 1000).to_i,
            expires_at: credential[:expires_at] ? Time.at(credential[:expires_at] / 1000.0) : nil
          }
        end

        def login_with_otp(challenge, otp, merchant_id: nil, store_id: nil)
          verification = verify_otp(challenge, otp)
          if merchant_id.nil? && resolve_single_merchant(verification[:merchants]).nil?
            return {
              status: "merchant-selection-required",
              verification: verification,
              merchants: verification[:merchants]
            }
          end

          session = complete_login(verification, merchant_id: merchant_id, store_id: store_id)
          { status: "complete", session: session }
        end

        def refresh_session(session)
          session = symbolize_state(session)
          validate_version(session, "session")
          switch_cred = session[:switch_credential]
          raise Error, "This Shopee session predates silent renewal; log in again with an OTP" unless switch_cred.is_a?(Hash)
          validate_strings(switch_cred, :toc_nonce, :spc_clientid, :device_fingerprint)

          restore_cookies(session[:cookies] || [])
          alive, payload, status = login_status
          unless alive
            raise Error.new("The Shopee account session has expired; log in again with an OTP", status, NOT_LOGIN_CODE, payload)
          end

          verification = {
            version: 1,
            toc_nonce: switch_cred[:toc_nonce],
            toc_userid: 0,
            spc_clientid: switch_cred[:spc_clientid],
            device_fingerprint: switch_cred[:device_fingerprint],
            cookies: session[:cookies] || [],
            merchants: session[:merchants]
          }

          merchant_id = session.dig(:merchant, :id)
          raise Error, "Shopee session has no selected merchant" if merchant_id.to_s.empty?
          _, credential = complete_base(verification, merchant_id)

          session.merge(
            cookies: snapshot_cookies,
            token: credential[:token],
            expires_at: credential[:expires_at] ? Time.at(credential[:expires_at] / 1000.0) : session[:expires_at]
          )
        end

        def parse_id_mobile(number)
          digits = number.to_s.gsub(/\D/, "")
          digits = digits.sub(/\A00/, "").sub(/\A62/, "").sub(/\A0/, "")
          unless digits.start_with?("8") && (9..13).cover?(digits.length)
            raise Error, "Enter a valid Indonesian mobile number"
          end

          { country_code: "62", subscriber: digits, national: "0#{digits}", e164: "62#{digits}" }
        end

        def format_phone_for_verification(e164)
          sub = e164.start_with?("62") ? e164[2..] : e164
          parts = [sub[0...3], sub[3...7], sub[7..]].reject { |p| p.to_s.empty? }
          "(+62) #{parts.join(' ')}"
        end

        def hash_shopee_password(password)
          return "" if password.to_s.empty?

          md5 = Digest::MD5.hexdigest(password)
          Digest::SHA256.hexdigest(md5)
        end

        def read_merchant_credential(cookies_list)
          cookies_list = symbolize_state(cookies_list)
          raise Error, "Invalid Shopee cookie snapshot" unless cookies_list.is_a?(Array)

          cookie = cookies_list.find { |c| c.is_a?(Hash) && c[:name] == LIVE_TOKEN_COOKIE && cookie_matches?(c, URI(PARTNER_BASE_URL)) }
          jwt = cookie ? cookie[:value] : nil
          raise Error, "Shopee login did not return a merchant session token" unless jwt.is_a?(String) && !jwt.empty?

          segments = jwt.split(".", -1)
          raise Error, "Invalid JWT format" unless segments.length == 3 && segments.all? { |segment| segment.match?(/\A[A-Za-z0-9_-]+\z/) }

          padded = segments[1] + ("=" * (-segments[1].bytesize % 4))
          payload = JSON.parse(Base64.urlsafe_decode64(padded), symbolize_names: true)
          raise Error, "Missing merchant token in JWT" unless payload.is_a?(Hash) && payload[:token].is_a?(String) && !payload[:token].empty?

          account_id = payload[:userid]
          raise Error, "Missing account id in JWT" unless (account_id.is_a?(String) || account_id.is_a?(Integer)) && !account_id.to_s.empty?

          {
            token: payload[:token],
            account_id: account_id.to_s,
            business_id: payload[:businessId]&.to_s,
            expires_at: payload[:exp].is_a?(Numeric) && payload[:exp].finite? ? (payload[:exp] * 1000).to_i : nil
          }
        rescue JSON::ParserError, ArgumentError => e
          raise Error, "Shopee returned an unreadable merchant session token: #{e.message}"
        end

        private

        def symbolize_state(value)
          case value
          when Hash
            raise Error, "Invalid Shopee state keys" unless value.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

            value.to_h { |key, item| [key.to_sym, symbolize_state(item)] }
          when Array then value.map { |item| symbolize_state(item) }
          when String then value.dup
          else value
          end
        end

        def validate_version(value, kind)
          raise Error, "Unsupported Shopee #{kind} version" unless value.is_a?(Hash) && value[:version] == 1
        end

        def validate_strings(value, *keys)
          unless keys.all? { |key| value[key].is_a?(String) && !value[key].strip.empty? }
            raise Error, "Incomplete Shopee authentication credentials"
          end
        end

        def partner_state
          login_auth = URI.encode_www_form_component("#{PARTNER_BASE_URL}/login/auth")
          base = URI.encode_www_form_component(PARTNER_BASE_URL)
          "#{PARTNER_BASE_URL}/?business_next=#{login_auth}&business_state=#{base}&business_client_id=#{BUSINESS_CLIENT_ID}"
        end

        def login_referer
          state = URI.encode_www_form_component(partner_state)
          auth = URI.encode_www_form_component("#{PARTNER_BASE_URL}/account/login/auth")
          "#{ACCOUNT_BASE_URL}/authenticate/login/?lang=id&should_hide_back=true&state=#{state}&client_id=#{ACCOUNT_CLIENT_ID}&next=#{auth}"
        end

        def bootstrap
          send_request(:get, "#{ACCOUNT_BASE_URL}/login?lang=id", headers: base_headers.merge("Accept" => "text/html"))
        end

        def device_fingerprint(device_report)
          headers = base_headers.merge(
            "Origin" => ACCOUNT_BASE_URL,
            "Referer" => "#{ACCOUNT_BASE_URL}/"
          )
          headers["Content-Type"] = "text/plain;charset=UTF-8"
          headers["szdet"] = (Time.now.to_f * 1000).to_i.to_s
          body = device_report

          resp = send_request(:post, DEVICE_FINGERPRINT_REPORT_URL, headers: headers, body: body)
          parsed = parse_json(resp)
          risk_token = parsed[:data].is_a?(Hash) ? parsed[:data][:riskToken] : nil
          if parsed[:code] != 0 || !risk_token.is_a?(String) || risk_token.empty?
            raise Error.new("Shopee device-risk service returned no risk token", resp.code.to_i, parsed[:code], parsed)
          end

          risk_token.to_s
        end

        def check_account_exists(phone, password, fingerprint)
          body = { phone: phone, password: hash_shopee_password(password) }
          account_request("/api/v4/account/business/check_account_exist_by_password", body, fingerprint)
        rescue Error => e
          if e.payload.is_a?(Hash)
            data = e.payload[:data]
            raise if e.payload[:captcha_required] == true || data.is_a?(Hash) && data[:captcha_required] == true
          end
          raise unless e.status && (200..299).cover?(e.status) && e.code.is_a?(Integer) && e.code != 0

          nil
        end

        def authenticate_by_password(phone, password, fingerprint)
          body = {
            phone: phone,
            password: hash_shopee_password(password),
            security_device_fingerprint: fingerprint
          }
          headers = account_headers(fingerprint).merge("Content-Type" => "application/json")
          resp = send_request(:post, "#{ACCOUNT_BASE_URL}/api/v4/account/business/authenticate_toc_by_password", headers: headers, body: JSON.generate(body))
          parsed = parse_json(resp)

          if parsed[:error] == NEED_OTP_CODE
            if password.to_s.empty?
              raise Error.new("#{PASSWORD_REQUIRED} (at /api/v4/account/business/authenticate_toc_by_password)", resp.code.to_i, parsed[:error], parsed)
            end

            return true
          end

          return false if parsed[:error] == 0 && parsed[:data].is_a?(Hash)
          # Only this empty-password response was observed to permit OTP requests.
          # Its provider meaning remains unknown; never bypass a supplied password.
          return nil if password.to_s.empty? && parsed[:error] == EMPTY_PASSWORD_CONTINUATION_CODE

          raise Error.new(
            "Shopee rejected password authentication at /api/v4/account/business/authenticate_toc_by_password (error #{parsed[:error]})",
            resp.code.to_i, parsed[:error], parsed
          )
        end

        def login_status
          headers = account_headers.merge("Content-Type" => "application/json")
          resp = send_request(:post, "#{ACCOUNT_BASE_URL}/api/v4/account/business/login_status", headers: headers, body: "{}")
          parsed = parse_json(resp)
          unless parsed[:error].is_a?(Integer)
            raise Error.new("Shopee returned a malformed login status at /api/v4/account/business/login_status", resp.code.to_i, parsed[:error], parsed)
          end
          unless [0, NOT_LOGIN_CODE].include?(parsed[:error])
            raise Error.new("Shopee login status failed at /api/v4/account/business/login_status", resp.code.to_i, parsed[:error], parsed)
          end
          [parsed[:error] == 0, parsed, resp.code.to_i]
        end

        def complete_base(verification, merchant_id)
          merchants = verification[:merchants] || []
          raise Error, "Shopee verification contains invalid merchants" unless merchants.is_a?(Array) && merchants.all? { |m| m.is_a?(Hash) }
          merchant = if merchant_id
                       merchants.find { |m| m[:id] == merchant_id.to_s }
                     else
                       resolve_single_merchant(merchants)
                     end

          raise Error, "Shopee merchant is not accessible" if merchant.nil?
          raise Error, "Shopee merchant has no staff account" unless merchant[:staff_user_id].is_a?(Integer) && merchant[:staff_user_id] > 0
          raise Error, "The selected Shopee merchant is inactive or banned" unless merchant[:is_active] == true && merchant[:is_banned] != true
          @cookies.delete_if { |_, cookie| cookie[:name] == LIVE_TOKEN_COOKIE && cookie_matches?(cookie, URI(PARTNER_BASE_URL)) }

          sso_exchange(
            verification[:toc_nonce].to_s,
            verification[:spc_clientid].to_s,
            verification[:device_fingerprint].to_s,
            merchant[:staff_user_id]
          )

          credential = read_merchant_credential(snapshot_cookies)
          raise Error, "Shopee returned a token for a different merchant" unless credential[:account_id] == merchant[:staff_user_id].to_s
          [merchant, credential]
        end

        def sso_exchange(toc_nonce, spc_clientid, fingerprint, staff_user_id)
          token_page = "#{ACCOUNT_BASE_URL}/authenticate/login/token/?lang=id" \
                       "&spc_clientid=#{URI.encode_www_form_component(spc_clientid)}" \
                       "&state=#{URI.encode_www_form_component(partner_state)}" \
                       "&tob_userid=#{staff_user_id}" \
                       "&next=#{URI.encode_www_form_component("#{PARTNER_BASE_URL}/account/login/tob/auth")}" \
                       "&client_id=#{ACCOUNT_CLIENT_ID}&toc_nonce=#{URI.encode_www_form_component(toc_nonce)}"
          follow_get(token_page)

          login = account_request(
            "/api/v4/account/business/login_toc",
            {
              toc_nonce: toc_nonce,
              tob_userid: staff_user_id,
              security_device_fingerprint: fingerprint
            },
            fingerprint
          )

          nonce = login[:nonce]
          raise Error, "Shopee merchant login returned no authorization code" unless nonce.is_a?(String) && !nonce.empty?

          exchange_url = "#{PARTNER_BASE_URL}/account/login/tob/auth?code=#{URI.encode_www_form_component(nonce.to_s)}&lang=id" \
                         "&spc_clientid=#{URI.encode_www_form_component(spc_clientid)}" \
                         "&state=#{URI.encode_www_form_component(partner_state)}"
          follow_get(exchange_url)
        end

        def get_profile(token, merchant_id)
          data = partner_request("/nb/mss/web-api/PartnerAccountServer/GetUserInfo", {}, token: token)
          found = data[:merchantId] || data[:merchant_id]
          found_s = found.to_s
          raise Error, "Shopee returned a profile for a different merchant" unless !found_s.empty? && found_s == merchant_id.to_s

          {
            merchant_id: found_s,
            merchant_name: data[:merchantName].to_s,
            store_id: data[:store_id]&.to_s,
            account_id: data[:tocUid]&.to_s,
            user_id: data[:tobUserId]&.to_s,
            user_name: (data[:userName] || data[:tocUserName]).to_s,
            raw: data
          }
        end

        def resolve_single_merchant(merchants)
          usable = usable_merchants(merchants)
          current = usable.select { |m| m[:is_current_login_user] == true }
          return current.first if current.size == 1
          return usable.first if usable.size == 1

          nil
        end

        def usable_merchants(merchants)
          (merchants || []).select { |m| m[:is_active] == true && m[:is_banned] != true }
        end

        def normalize_merchant(raw)
          return nil unless raw.is_a?(Hash)

          merchant_id = raw[:merchantId]
          staff_uid = raw[:staffTobUid]
          return nil unless merchant_id.is_a?(Integer) && merchant_id > 0 && staff_uid.is_a?(Integer) && staff_uid > 0

          {
            id: merchant_id.to_s,
            name: raw[:merchantName].to_s,
            status: raw[:merchantStatus].to_i,
            staff_user_id: staff_uid,
            is_active: raw[:isActive] == true,
            is_banned: raw[:isBanned] == true,
            is_current_login_user: raw[:isCurrentLoginUser] == true
          }
        end

        def choose_store_id(stores, requested, profile_store)
          if requested
            raise Error, "Shopee store is not accessible" unless stores.any? { |s| s[:id].to_s == requested.to_s }

            return requested.to_s
          end
          return profile_store if profile_store && stores.any? { |s| s[:id] == profile_store.to_s }
          return stores.first[:id] if stores.size == 1

          nil
        end

        def account_request(path, body, fingerprint = nil)
          headers = account_headers(fingerprint).merge("Content-Type" => "application/json")
          resp = send_request(:post, "#{ACCOUNT_BASE_URL}#{path}", headers: headers, body: JSON.generate(body))
          parsed = parse_json(resp)

          if parsed[:error] != 0 || !parsed[:data].is_a?(Hash)
            err = Response.error(parsed)
            raise Error.new("Shopee account request failed at #{path}: #{err || 'invalid response'}", resp.code.to_i, parsed[:error], parsed)
          end

          parsed[:data].is_a?(Hash) ? parsed[:data] : {}
        end

        def partner_request(path, body, token: "", toc_nonce: nil)
          headers = {
            "Accept" => "application/json, text/plain, */*",
            "User-Agent" => Client::USER_AGENT,
            "Accept-Language" => "id,en-US;q=0.9,en;q=0.8",
            "Content-Type" => "application/json",
            "Origin" => PARTNER_BASE_URL,
            "Referer" => "#{PARTNER_BASE_URL}/",
            "X-Merchant-ToB-Clientid" => "undefined",
            "X-Merchant-Login-From" => PARTNER_LOGIN_FROM,
            "X-Merchant-From" => PARTNER_LOGIN_FROM,
            "X-Merchant-Language" => "id",
            "X-Merchant-Timezone" => "Asia/Jakarta",
            "X-Merchant-RequestId" => SecureRandom.uuid,
            "shopee-baggage" => "PFB=undefined",
            "X-Merchant-Token" => token
          }
          headers["X-Merchant-ToC-Nonce"] = toc_nonce if toc_nonce

          resp = send_request(:post, "#{PARTNER_API_BASE_URL}#{path}", headers: headers, body: JSON.generate(body), send_cookies: false)
          parsed = parse_json(resp)

          if parsed[:errorCode] != 0 || !parsed[:data].is_a?(Hash)
            err = Response.error(parsed)
            raise Error.new(err || "Shopee partner request failed at #{path}", resp.code.to_i, parsed[:errorCode], parsed)
          end

          parsed[:data].is_a?(Hash) ? parsed[:data] : {}
        end

        def follow_get(url, max_redirects = 5)
          current = url
          (max_redirects + 1).times do
            uri = URI(current)
            unless uri.scheme == "https" && [URI(ACCOUNT_BASE_URL).host, URI(PARTNER_BASE_URL).host].include?(uri.host) && uri.port == 443 && uri.userinfo.nil?
              raise Error, "Shopee redirect targets an untrusted URL"
            end
            resp = send_request(:get, current, headers: base_headers)
            return resp if (200..299).cover?(resp.code.to_i)
            unless [301, 302, 303, 307, 308].include?(resp.code.to_i)
              raise Error.new("Shopee HTTP request failed", resp.code.to_i)
            end
            location = resp["location"]
            raise Error, "Shopee redirect missing location header" if location.to_s.empty?

            current = URI.join(current, location).to_s
          end
          raise Error, "Shopee redirect limit exceeded"
        end

        def send_request(method, url, headers:, body: nil, send_cookies: true)
          uri = URI(url)
          raise Error, "Shopee requests require HTTPS" unless uri.scheme == "https" && uri.userinfo.nil?
          req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
          headers.each { |k, v| req[k] = v }

          if send_cookies
            cookie_header = build_cookie_header(uri)
            req["Cookie"] = cookie_header unless cookie_header.empty?
          end

          req.body = body if body

          response = execute_request(req, uri)
          update_cookies(response, uri) if send_cookies
          unless (200..399).cover?(response.code.to_i)
            raise Error.new("Shopee HTTP request failed", response.code.to_i)
          end
          response
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED => e
          raise Error, "Shopee network error: #{e.message}"
        end

        def execute_request(req, uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 10
          http.read_timeout = 15
          http.request(req)
        end

        def parse_json(response)
          unless (200..299).cover?(response.code.to_i)
            raise Error.new("Shopee HTTP request failed", response.code.to_i)
          end
          parsed = JSON.parse(response.body.to_s, symbolize_names: true)
          raise Error.new("Shopee returned a malformed JSON envelope", response.code.to_i) unless parsed.is_a?(Hash)
          if parsed[:captcha_required] == true || parsed[:data].is_a?(Hash) && parsed[:data][:captcha_required] == true
            raise Error.new(Response.error(parsed), response.code.to_i, parsed[:error] || parsed[:errorCode] || parsed[:code], parsed)
          end

          parsed
        rescue JSON::ParserError
          raise Error.new("Shopee returned invalid JSON (HTTP #{response.code})", response.code.to_i)
        end

        def base_headers
          {
            "Accept" => "application/json, text/plain, */*",
            "User-Agent" => Client::USER_AGENT,
            "Accept-Language" => "id,en-US;q=0.9,en;q=0.8",
            "Sec-Fetch-Dest" => "empty",
            "Sec-Fetch-Mode" => "cors",
            "Sec-Fetch-Site" => "same-site"
          }
        end

        def account_headers(fingerprint = nil)
          headers = base_headers.merge(
            "Origin" => ACCOUNT_BASE_URL,
            "Referer" => login_referer,
            "X-App-Type" => "2",
            "Sec-Fetch-Site" => "same-origin",
            "Priority" => "u=0"
          )
          if fingerprint
            headers["af-ac-enc-sz-token"] = fingerprint
            headers["x-sz-sdk-version"] = SZ_SDK_VERSION
          end
          csrf = jar_get(CSRF_COOKIE, ACCOUNT_BASE_URL)
          headers["X-CSRFToken"] = csrf if csrf
          headers
        end

        def update_cookies(response, uri)
          (response.get_fields("set-cookie") || []).each do |header|
            pair, *attributes = header.split(";")
            name, value = pair.strip.split("=", 2)
            next if name.to_s.empty? || value.nil? || name.match?(/[\s,]/) || value.match?(/[\r\n]/)

            attrs = attributes.to_h { |attribute| key, val = attribute.strip.split("=", 2); [key.downcase, val] }
            domain = (attrs["domain"] || uri.host).downcase.sub(/\A\./, "")
            next unless domain == uri.host || (domain.end_with?(".shopee.co.id") || domain == "shopee.co.id") && uri.host.end_with?(".#{domain}")

            default_path = uri.path.sub(%r{/[^/]*\z}, "")
            default_path = "/" unless default_path.start_with?("/") && !default_path.empty?
            path = attrs["path"].to_s.start_with?("/") ? attrs["path"] : default_path
            expires = begin
              Time.httpdate(attrs["expires"]).to_f if attrs["expires"]
            rescue ArgumentError
              nil
            end
            expires = Time.now.to_f + attrs["max-age"].to_i if attrs["max-age"].to_s.match?(/\A-?\d+\z/)
            cookie = { name: name, value: value, domain: domain, path: path, secure: attrs.key?("secure"), host_only: !attrs.key?("domain"), expires: expires }
            key = [name, domain, path]
            if expires && expires <= Time.now.to_f
              @cookies.delete(key)
            else
              @cookies[key] = cookie
            end
          end
        end

        def cookie_matches?(cookie, uri)
          domain = cookie[:domain].to_s.sub(/\A\./, "")
          path = cookie[:path].to_s
          request_path = uri.path.empty? ? "/" : uri.path
          domain_match = uri.host == domain || cookie[:host_only] != true && uri.host.end_with?(".#{domain}")
          path_match = request_path == path || request_path.start_with?(path.end_with?("/") ? path : "#{path}/")
          domain_match && path_match && (!cookie[:secure] || uri.scheme == "https") && (!cookie[:expires] || cookie[:expires] > Time.now.to_f)
        end

        def matching_cookies(uri)
          @cookies.delete_if { |_, cookie| cookie[:expires] && cookie[:expires] <= Time.now.to_f }
          @cookies.values.select { |cookie| cookie_matches?(cookie, uri) }.sort_by { |cookie| -cookie[:path].length }
        end

        def build_cookie_header(uri)
          matching_cookies(uri).map { |cookie| "#{cookie[:name]}=#{cookie[:value]}" }.join("; ")
        end

        def jar_get(name, domain_url)
          matching_cookies(URI(domain_url)).find { |cookie| cookie[:name] == name }&.dig(:value)
        end

        def snapshot_cookies
          @cookies.delete_if { |_, cookie| cookie[:expires] && cookie[:expires] <= Time.now.to_f }
          symbolize_state(@cookies.values)
        end

        def restore_cookies(cookie_list)
          raise Error, "Invalid Shopee cookie snapshot" unless cookie_list.is_a?(Array)

          @cookies.clear
          cookie_list.each do |raw|
            raise Error, "Invalid Shopee cookie snapshot" unless raw.is_a?(Hash)

            cookie = raw.transform_keys(&:to_sym)
            name = cookie[:name].to_s
            domain = cookie[:domain].to_s.downcase.sub(/\A\./, "")
            path = cookie[:path].to_s
            next if name.empty? || !(domain == "shopee.co.id" || domain.end_with?(".shopee.co.id")) || !path.start_with?("/")
            next if name.match?(/[\s,;]/) || cookie[:value].to_s.match?(/[\r\n;]/)
            next if cookie[:expires] && (!cookie[:expires].is_a?(Numeric) || !cookie[:expires].finite?)

            @cookies[[name, domain, path]] = symbolize_state(cookie.merge(name: name, value: cookie[:value].to_s, domain: domain, path: path))
          end
        end
      end
    end
  end
end
