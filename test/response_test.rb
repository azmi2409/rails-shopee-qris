# frozen_string_literal: true

require_relative "test_helper"

class ResponseTest < Minitest::Test
  def test_unmapped_codes_remain_visible_to_callers
    [12_345, 10_002, 48_401_003].each do |code|
      assert_includes Rails::Shopee::Qris::Response.error(code: code), code.to_s
    end
  end

  def test_success_responses_have_no_error
    assert_nil Rails::Shopee::Qris::Response.error(code: 0, msg: "", data: {})
  end

  def test_malformed_zero_codes_do_not_hide_provider_errors
    [0.0, 0.5, " 0", "+0", false].each do |code|
      assert_equal "provider rejected credential", Rails::Shopee::Qris::Response.error(code: code, msg: "provider rejected credential")
    end
    assert_nil Rails::Shopee::Qris::Response.error(code: "0", msg: "success")
  end

  def test_captcha_and_nested_errors_survive_success_code
    assert_equal "risk challenge", Rails::Shopee::Qris::Response.error(code: 0, data: { errors: [{ message: "risk challenge" }] })
    assert Rails::Shopee::Qris::Response.error(code: 0, data: { captcha_required: true })
  end
end
