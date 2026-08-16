# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class ReleaseMatrixTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  VERIFIER = REPOSITORY_ROOT.join("bin/verify-release-matrix").to_s
  CONTRACT_PATH = "docs/contracts/release_matrix.yml"
  WORKFLOW_PATH = ".github/workflows/ci.yml"

  setup do
    @root = Dir.mktmpdir("hitch-release-matrix")
    copy(CONTRACT_PATH)
    copy(WORKFLOW_PATH)
    copy("lib/hitch/version.rb")
    matrix.fetch("lanes").each do |lane|
      copy(lane.fetch("gemfile"))
      copy("#{lane.fetch('gemfile')}.lock")
    end
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts the exact four locked and hosted release lanes" do
    stdout, stderr, status = run_verifier

    assert_predicate status, :success?, stderr
    assert_includes stdout, "4 Rails/SDK/database lanes"
  end

  test "rejects a missing contract lane" do
    mutate_contract { |contract| contract.fetch("lanes").pop }

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact four-lane 0.2 matrix"
  end

  test "rejects a floating or mismatched Gemfile declaration" do
    lane = matrix.fetch("lanes").first
    path = File.join(@root, lane.fetch("gemfile"))
    File.write(path, File.read(path).sub('gem "mcp", "= 1.1.0"', 'gem "mcp", ">= 1.0"'))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "gem declarations drifted"
  end

  test "rejects a lock that violates the minimum SDK lane" do
    lane = matrix.fetch("lanes").first
    path = File.join(@root, "#{lane.fetch('gemfile')}.lock")
    File.write(path, File.read(path).sub("    mcp (1.1.0)", "    mcp (1.0.0)"))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "locked mcp violates = 1.1.0"
    assert_includes stderr, "minimum SDK lane must resolve exactly 1.1.0"
  end

  test "rejects hosted CI that omits or remaps a release lane" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    workflow.dig("jobs", "supported-matrix", "strategy", "matrix", "include").pop
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact four release-matrix rows"
  end

  test "rejects a hosted SQLite lane with no lock wait" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    sqlite_lane = workflow.dig("jobs", "supported-matrix", "strategy", "matrix", "include").first
    sqlite_lane["database_url"] = sqlite_lane.fetch("database_url").delete_suffix("?timeout=5000")
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact four release-matrix rows"
  end

  test "rejects a shallow checkpoint checkout" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    checkout = workflow.dig("jobs", "checkpoint-gates", "steps").find do |step|
      step["uses"] == "actions/checkout@v6"
    end
    checkout.delete("with")
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "fetch full history for sealed artifact reconstruction"
  end

  test "rejects a no-op supported matrix workflow" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    workflow.dig("jobs", "supported-matrix")["steps"] = [ { "run" => "true" } ]
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact checkout setup database eager-load and test steps"
  end

  test "rejects an aggregate checkpoint job that can bypass matrix results" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    workflow.dig("jobs", "checkpoint-gates")["needs"] = [ "sdk-lanes" ]
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "depend on both supported-matrix and sdk-lanes"
  end

  test "the appraisal dispatcher exposes every release profile" do
    stdout, stderr, status = Open3.capture3(REPOSITORY_ROOT.join("bin/ci-appraisal").to_s, "--help")

    assert_predicate status, :success?, stderr
    matrix.fetch("lanes").each { |lane| assert_includes stdout + stderr, lane.fetch("name") }
  end

  test "release appraisal tests force test mode and always provision a disposable database" do
    source = REPOSITORY_ROOT.join("bin/ci-appraisal").read

    assert_includes source, '"RAILS_ENV" => "test"'
    refute_includes source, '"RAILS_ENV" => ENV.fetch("RAILS_ENV"'
    assert_includes source, "if rails_test_command\n"
    refute_includes source, "database_url_was_explicit"
    assert_includes source, "cleanup_succeeded = system("
    assert_includes source, "result = 1 if result.zero?"
    refute_match(/ensure[\s\S]*?system\([^\n]*db:drop[^\n]*\)\n\s*end/, source)
    assert_includes source, 'ENV.fetch("HITCH_APPRAISAL_POSTGRES_URL", "postgresql:///postgres")'
  end

  test "migration gate fails closed when PostgreSQL cleanup fails" do
    source = REPOSITORY_ROOT.join("bin/ci-migrations").read

    assert_includes source, "primary_failure = $!"
    assert_includes source, "cleanup_succeeded = system("
    assert_includes source, 'RuntimeError.new("failed to drop the disposable PostgreSQL migration database")'
    assert_includes source, "raise cleanup_failure unless primary_failure"
    assert_includes source, 'warn "PostgreSQL migration cleanup also failed: #{cleanup_failure.message}"'
  end

  test "hosted PostgreSQL lanes use the dedicated disposable database authority" do
    path = File.join(@root, WORKFLOW_PATH)
    workflow = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    workflow.dig("jobs", "supported-matrix", "env").delete("HITCH_APPRAISAL_POSTGRES_URL")
    File.write(path, YAML.dump(workflow))

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "dedicated disposable PostgreSQL base"
  end

  private

  def matrix
    @matrix ||= YAML.safe_load_file(File.join(@root, CONTRACT_PATH), permitted_classes: [], aliases: false)
  end

  def run_verifier
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root)
  end

  def mutate_contract
    path = File.join(@root, CONTRACT_PATH)
    contract = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    yield contract
    File.write(path, YAML.dump(contract))
    @matrix = nil
  end

  def copy(relative_path)
    destination = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(REPOSITORY_ROOT.join(relative_path), destination)
  end
end
