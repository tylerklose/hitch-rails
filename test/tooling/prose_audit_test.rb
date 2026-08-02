# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class ProseAuditTest < ActiveSupport::TestCase
  COMMAND = Rails.root.join("../../bin/prose-audit").expand_path.to_s

  test "current maintained prose has no stale mechanism claims" do
    stdout, stderr, status = Open3.capture3(COMMAND)

    assert_predicate status, :success?, stderr
    assert_includes stdout, "patterns=31"
    assert_includes stdout, "allowlisted_historical_fixtures=3"
    assert_includes stdout, "stale_matches=0"
    searched = stdout[/^searched_files=(\d+)$/, 1].to_i
    assert_operator searched, :>, 250
  end

  test "superseded generator production doctor and publication claims fail" do
    Dir.mktmpdir("hitch-prose-audit") do |root|
      production_memory = [
        [ "Production", " uses " ].join,
        [ "the memory", " rate store." ].join
      ].join
      stale_lines = [
        [ "The tool generator ", "registers the tool automatically." ].join,
        production_memory,
        [ "hitch:doctor ", "repairs configuration for you." ].join,
        [ "0.2.0.pre.4 ", "is publicly published." ].join
      ]
      File.write(File.join(root, "README.md"), stale_lines.join("\n"))

      _stdout, stderr, status = Open3.capture3(COMMAND, "--root", root)

      assert_equal 1, status.exitstatus
      assert_includes stderr, "tool generator auto-registration"
      assert_includes stderr, "production memory rate store"
      assert_includes stderr, "doctor repair mode"
      assert_includes stderr, "premature pre4 publication"
    end
  end

  test "immutable historical evidence is outside the live prose surface" do
    Dir.mktmpdir("hitch-prose-audit") do |root|
      FileUtils.mkdir_p(File.join(root, "docs/evidence/0.2.0"))
      File.write(File.join(root, "README.md"), "Current operator documentation.\n")
      File.write(
        File.join(root, "docs/evidence/0.2.0/historical.md"),
        [ "In production ", "the memory rate store is supported." ].join
      )

      stdout, stderr, status = Open3.capture3(COMMAND, "--root", root)

      assert_predicate status, :success?, stderr
      assert_includes stdout, "searched_files=1"
      assert_includes stdout, "stale_matches=0"
    end
  end
end
