# frozen_string_literal: true

require_relative "test_helper"

class QrisTest < Minitest::Test
  def setup
    merchant = "ID.CO.SHOPEEPAY.WWW"
    name = "SHOPEE STORE"
    @base = "00020101021126#{merchant.bytesize.to_s.rjust(2, "0")}#{merchant}53033605802ID59#{name.bytesize.to_s.rjust(2, "0")}#{name}6007JAKARTA6304"
    @template = @base + Rails::Shopee::Qris::Qris.crc16(@base)
    Rails::Shopee::Qris.configuration.static_qris = @template
  end

  def test_generates_dynamic_qris_with_exact_amount
    result = Rails::Shopee::Qris::Qris.generate(@template, 75_000)
    tags = Rails::Shopee::Qris::Qris.parse(result)

    assert_equal "12", tags.assoc("01").last
    assert_equal "75000", tags.assoc("54").last
    assert_equal Rails::Shopee::Qris::Qris.crc16(result[0...-4]), result[-4, 4]
  end

  def test_rejects_invalid_checksum
    assert_raises(Rails::Shopee::Qris::Error) do
      Rails::Shopee::Qris::Qris.generate(@template.sub(/.\z/, "0"), 75_000)
    end
  end

  def test_rejects_fractional_and_oversized_amounts
    client = Rails::Shopee::Qris::Client.new
    [1.9, "1.9", true, "1" * 100].each do |amount|
      assert_raises(Rails::Shopee::Qris::Error) { client.create_qris(amount: amount) }
    end
  end

  def test_rejects_zero_or_negative_amount
    assert_raises(Rails::Shopee::Qris::Error) do
      Rails::Shopee::Qris::Qris.generate(@template, 0)
    end
    assert_raises(Rails::Shopee::Qris::Error) do
      Rails::Shopee::Qris::Qris.generate(@template, -5000)
    end
  end

  def test_rejects_duplicate_tags_and_non_decimal_lengths
    qris = Rails::Shopee::Qris::Qris
    duplicate = @base.sub("6304", "5802ID6304")
    duplicate += qris.crc16(duplicate)
    refute qris.valid_static?(duplicate)
    assert_equal [], qris.parse("00+201")
  end
end
