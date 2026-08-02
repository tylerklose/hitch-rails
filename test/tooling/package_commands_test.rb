# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class PackageCommandsTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path

  setup do
    @root = Dir.mktmpdir("hitch-package-commands")
    bin = File.join(@root, "bin")
    FileUtils.mkdir_p(bin)
    %w[client-smokes package-apps].each do |command|
      FileUtils.cp(REPOSITORY_ROOT.join("bin", command), File.join(bin, command))
    end
    File.write(File.join(bin, "package-smoke"), <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      puts JSON.generate(
        "arguments" => ARGV,
        "automated_environment" => ENV["HITCH_AUTOMATED_CLIENT_SMOKES"]
      )
    RUBY
    FileUtils.chmod(0o755, Dir[File.join(bin, "*")])
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "package-apps delegates to the package authority in apps-only mode" do
    stdout, stderr, status = run_command(
      "package-apps",
      environment: { "HITCH_AUTOMATED_CLIENT_SMOKES" => "1" }
    )

    assert_predicate status, :success?, stderr
    assert_equal({ "arguments" => [], "automated_environment" => nil }, JSON.parse(stdout))
  end

  test "client-smokes maps its public automated option to the package authority" do
    stdout, stderr, status = run_command(
      "client-smokes", "--automated",
      environment: { "HITCH_AUTOMATED_CLIENT_SMOKES" => "invalid" }
    )

    assert_predicate status, :success?, stderr
    assert_equal(
      { "arguments" => [ "--automated-clients" ], "automated_environment" => nil },
      JSON.parse(stdout)
    )
  end

  test "package command surfaces reject unsupported arguments before building" do
    [ [ "package-apps", "unexpected" ], [ "client-smokes" ], [ "client-smokes", "--manual" ] ].each do |command|
      stdout, stderr, status = run_command(*command)

      assert_equal 64, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "Usage: bin/"
    end
  end

  test "package-smoke rejects unsupported internal modes before building" do
    stdout, stderr, status = Open3.capture3(
      REPOSITORY_ROOT.join("bin/package-smoke").to_s,
      "--unsupported"
    )

    assert_equal 64, status.exitstatus
    assert_empty stdout
    assert_includes stderr, "Usage: bin/package-smoke [--automated-clients]"
  end

  private

  def run_command(command, *arguments, environment: {})
    Open3.capture3(environment, File.join(@root, "bin", command), *arguments)
  end
end
