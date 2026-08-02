# frozen_string_literal: true

require "test_helper"

class HitchVersionTest < ActiveSupport::TestCase
  test "version is set" do
    assert Hitch::VERSION
  end
end
