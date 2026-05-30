# frozen_string_literal: true

require "test_helper"

class Hitch::EngineTest < ActiveSupport::TestCase
  test "host filter_parameters extended with OAuth secrets" do
    # Rails 8 consolidates filter_parameters into a single regex for
    # performance — assert behavior by actually filtering a sample hash
    # rather than introspecting the (post-consolidation) array shape.
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "code" => "raw_auth_code",
      "code_verifier" => "raw_verifier",
      "access_token" => "raw_access_token",
      "authorization_code" => "raw_auth_code",
      "token" => "raw_token",
      "client_name" => "Claude"  # control: not filtered
    )
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "[FILTERED]", filtered["code_verifier"]
    assert_equal "[FILTERED]", filtered["access_token"]
    assert_equal "[FILTERED]", filtered["authorization_code"]
    assert_equal "[FILTERED]", filtered["token"]
    assert_equal "Claude", filtered["client_name"]
  end
end
