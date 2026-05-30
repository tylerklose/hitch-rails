# frozen_string_literal: true

require "test_helper"

class HitchVersionTest < ActiveSupport::TestCase
  test "version is set" do
    assert Hitch::VERSION
  end

  test "configuration defaults principal_model to User" do
    Hitch.reset_configuration!
    assert_equal "User", Hitch.configuration.principal_model
  end

  test "configure block updates principal_model" do
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "Account"
      c.resource_uri = "https://example.com/mcp"
    end
    assert_equal "Account", Hitch.configuration.principal_model
    assert_equal "https://example.com/mcp", Hitch.configuration.resource_uri
  end
end
