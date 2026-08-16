# frozen_string_literal: true

require "test_helper"
require "open3"

class DoctorFixturesDispatchTest < ActiveSupport::TestCase
  COMMAND = Rails.root.join("../../bin/doctor-fixtures").expand_path.to_s

  test "advertises its argument-free contract" do
    stdout, stderr, status = Open3.capture3(COMMAND, "--help")

    assert_predicate status, :success?, stdout
    assert_empty stdout
    assert_includes stderr, "Usage: bin/doctor-fixtures"
  end

  test "rejects unexpected arguments" do
    _stdout, stderr, status = Open3.capture3(COMMAND, "unexpected")

    assert_equal 64, status.exitstatus
    assert_includes stderr, "Unexpected arguments"
    assert_includes stderr, "Usage: bin/doctor-fixtures"
  end

  test "runs the accepted Lattice and task fixture target" do
    stdout, stderr, status = Open3.capture3(COMMAND)

    assert_predicate status, :success?, stderr
    assert_includes stdout, "Hitch doctor verified: 28 pairwise rows"
    assert_match(/\d+ runs, \d+ assertions, zero skips/, stdout)
  end
end
