# frozen_string_literal: true

require_relative "test_helper"

class ResponseTest < Minitest::Test
  def test_maps_bare_provider_codes_to_actionable_text
    assert_equal "Shopee rejected the token as invalid or expired",
                 Rails::Shopee::Qris::Response.error(code: 200020, msg: "")
    assert_equal "Shopee rejected the OTP code as wrong or expired",
                 Rails::Shopee::Qris::Response.error(error: 48401003)
    assert_equal "Shopee refused to send the OTP on the requested channel",
                 Rails::Shopee::Qris::Response.error(code: "48401103")
  end

  def test_prefers_provider_message_over_the_generic_hint
    assert_equal "invalid token, err", Rails::Shopee::Qris::Response.error(code: 200020, msg: "invalid token, err")
  end

  def test_unknown_code_still_reports_the_number
    assert_equal "Shopee error (code 12345)", Rails::Shopee::Qris::Response.error(code: 12_345)
  end

  def test_success_responses_have_no_error
    assert_nil Rails::Shopee::Qris::Response.error(code: 0, msg: "", data: {})
  end
end
