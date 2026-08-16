# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../../tooling/package_distribution"

class PackageDistributionTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-package-distribution")
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  test "conditional RC distribution remains internal after pre4 deferral" do
    write_decision("deferred_to_final")

    assert_equal "internal_only", resolve("public_if_pre4_published")
  end

  test "conditional RC distribution becomes public eligible only after pre4 publication" do
    write_decision("published_pre4")

    assert_equal "public_eligible", resolve("public_if_pre4_published")
  end

  test "development artifacts remain internal regardless of the recorded decision" do
    assert_equal "internal_only",
      HitchPackageDistribution.resolve(
        root: @root,
        declared: "public_if_pre4_published",
        development: true
      )
  end

  test "conditional distribution fails closed on an invalid decision" do
    write_decision("unknown")

    error = assert_raises(RuntimeError) { resolve("public_if_pre4_published") }
    assert_includes error.message, "decision is invalid"
  end

  private

  def resolve(declared)
    HitchPackageDistribution.resolve(root: @root, declared:, development: false)
  end

  def write_decision(decision)
    path = File.join(@root, HitchPackageDistribution::DECISION_PATH)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate("decision" => decision)}\n")
  end
end
