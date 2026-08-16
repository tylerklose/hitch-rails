# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../../tooling/exclusive_report"

class ExclusiveReportTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-exclusive-report-root")
    @outside = Dir.mktmpdir("hitch-exclusive-report-outside")
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside) if File.exist?(@outside)
  end

  test "creates one private report outside the repository without overwrite" do
    path = File.join(@outside, "report.json")

    result = HitchExclusiveReport.write!(
      root: @root,
      path:,
      bytes: "report\n",
      variable: "HITCH_REPORT"
    )

    assert_equal File.join(File.realpath(@outside), "report.json"), result
    assert_equal "report\n", File.binread(path)
    assert_equal 0o600, File.stat(path).mode & 0o777
    error = assert_raises(ArgumentError) do
      HitchExclusiveReport.write!(root: @root, path:, bytes: "replacement", variable: "HITCH_REPORT")
    end
    assert_includes error.message, "must not already exist"
    assert_equal "report\n", File.binread(path)
  end

  test "rejects repository paths and outside symlinks targeting repository files" do
    tracked = File.join(@root, "tracked.json")
    File.write(tracked, "original\n")

    direct_error = assert_raises(ArgumentError) do
      HitchExclusiveReport.write!(root: @root, path: tracked, bytes: "overwrite", variable: "HITCH_REPORT")
    end
    assert_includes direct_error.message, "outside the repository"

    link = File.join(@outside, "report.json")
    File.symlink(tracked, link)
    symlink_error = assert_raises(ArgumentError) do
      HitchExclusiveReport.write!(root: @root, path: link, bytes: "overwrite", variable: "HITCH_REPORT")
    end
    assert_includes symlink_error.message, "must not already exist"
    assert_equal "original\n", File.binread(tracked)
  end
end
