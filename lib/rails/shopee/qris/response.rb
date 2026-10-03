# frozen_string_literal: true

module Rails
  module Shopee
    module Qris
      module Response
        module_function

        # Shopee answers many failures with a bare numeric code and no message.
        # Map the ones we have observed so callers get something actionable.
        CODE_HINTS = {
          200020 => "Shopee rejected the token as invalid or expired",
          2010000 => "Shopee request carried no token",
          48401102 => "Shopee requires the account password before sending an OTP",
          48401103 => "Shopee refused to send the OTP on the requested channel",
          48500102 => "The Shopee account session has expired; log in again with an OTP"
        }.freeze

        def data(payload)
          code = payload[:code] if payload.is_a?(Hash)
          success = (code.is_a?(Integer) && code.zero?) || code == "0"
          unless payload.is_a?(Hash) && success && payload[:data].is_a?(Hash)
            raise Error, "Shopee returned an invalid payment response envelope"
          end

          payload[:data]
        end

        def error(payload)
          return "Shopee returned a non-object response" unless payload.is_a?(Hash)

          inner = payload[:data].is_a?(Hash) ? payload[:data] : {}
          if payload[:captcha_required] == true || inner[:captcha_required] == true
            return "Shopee requires a captcha challenge; solve in browser or renew session"
          end

          code = payload[:code] || payload[:errorCode] || payload[:error]
          code_i = if code.is_a?(Integer)
                     code
                   elsif code.is_a?(String) && code.match?(/\A-?\d+\z/)
                     Integer(code, 10)
                   end
          is_success_code = code_i == 0

          errors = payload[:errors] || inner[:errors]
          messages = extract(errors)

          unless is_success_code
            msg = payload[:msg] || payload[:errorMsg] || payload[:error_msg] || payload[:message] ||
                  inner[:msg] || inner[:errorMsg] || inner[:error_msg]
            description = payload[:error_description] || inner[:error_description]

            messages << msg.to_s unless msg.to_s.empty?
            messages << description.to_s unless description.to_s.empty?
            messages << (CODE_HINTS[code_i] || "Shopee error (code #{code})") if messages.empty? && !code.nil?
          end
          return nil if messages.empty?

          messages.uniq.join("; ")
        end

        def extract(errors)
          case errors
          when nil then []
          when Array then errors.filter_map { |item| item.is_a?(Hash) ? (item[:message] || item[:code] || item[:msg]) : item }
          when Hash then [errors[:message] || errors[:code] || errors[:msg]]
          else [errors]
          end.compact.map(&:to_s).reject(&:empty?)
        end
        private_class_method :extract
      end
    end
  end
end
