# frozen_string_literal: true

module Rails
  module Shopee
    module Qris
      class Error < StandardError
        attr_reader :status, :code, :payload

        def initialize(message, status = nil, code = nil, payload = nil)
          @status = status
          @code = code
          @payload = payload
          super(message)
        end
      end
    end
  end
end
