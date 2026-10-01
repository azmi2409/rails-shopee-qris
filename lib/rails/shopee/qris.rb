# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "time"
require "uri"

module Rails
  module Shopee
    module Qris
      class Configuration
        attr_accessor :phone_number, :static_qris, :token, :store_id, :merchant_id, :device_report
      end

      class << self
        def configuration
          @configuration ||= Configuration.new
        end

        def configure
          yield configuration
        end
      end
    end
  end
end

require_relative "qris/error"
require_relative "qris/response"
require_relative "qris/qris"
require_relative "qris/client"
require_relative "qris/setup"
