# frozen_string_literal: true

require "test_helper"
require "open3"

class CIGeneratorsDispatchTest < ActiveSupport::TestCase
  COMMAND = Rails.root.join("../../bin/ci-generators").expand_path.to_s

  test "advertises the two owned generator targets" do
    _stdout, stderr, status = Open3.capture3(COMMAND, "--help")

    assert_predicate status, :success?, stderr
    assert_includes stderr, "Usage: bin/ci-generators (install|tool)"
  end

  test "fails closed while each downstream generator packet is pending" do
    { "install" => "M5.1", "tool" => "M5.2" }.each do |target, owner|
      _stdout, stderr, status = Open3.capture3(COMMAND, target)

      assert_equal 69, status.exitstatus
      assert_includes stderr, "intentionally unavailable until #{owner}"
    end
  end

  test "rejects missing unknown and extra targets" do
    [ [], [ "other" ], [ "install", "extra" ] ].each do |arguments|
      _stdout, stderr, status = Open3.capture3(COMMAND, *arguments)

      assert_equal 64, status.exitstatus
      assert_includes stderr, "Usage: bin/ci-generators (install|tool)"
    end
  end
end
