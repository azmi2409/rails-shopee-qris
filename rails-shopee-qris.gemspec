# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rails-shopee-qris"
  spec.version = "0.2.0"
  spec.authors = ["Azmi"]
  spec.summary = "Unofficial ShopeePay QRIS client"
  spec.description = "Generate dynamic QRIS codes and access ShopeePay merchant transactions."
  spec.homepage = "https://github.com/azmi2409/rails-shopee-qris"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "allowed_push_host" => "https://rubygems.org"
  }
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
