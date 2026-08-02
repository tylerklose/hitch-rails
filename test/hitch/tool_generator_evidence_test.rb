# frozen_string_literal: true

require "test_helper"
require "digest"
require "erb"
require "json"
require "open3"
require "time"

class Hitch::ToolGeneratorEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/generators/tool.json")
  SOURCE_FILES = {
    "generator_sha256" => "lib/generators/hitch/tool_generator.rb",
    "tool_template_sha256" => "lib/generators/hitch/tool/templates/tool.rb.tt",
    "test_template_sha256" => "lib/generators/hitch/tool/templates/tool_test.rb.tt",
    "public_test_helper_sha256" => "lib/hitch/mcp/test_helper.rb",
    "generator_test_sha256" => "test/hitch/tool_generator_test.rb",
    "public_test_helper_test_sha256" => "test/hitch/mcp_test_helper_test.rb",
    "lattice_schema_sha256" => "test/lattice/tool_generator.json",
    "lattice_scenarios_sha256" => "test/lattice/tool_generator_scenarios.json",
    "generator_runner_sha256" => "bin/ci-generators",
    "generator_dispatch_test_sha256" => "test/tooling/ci_generators_dispatch_test.rb",
    "package_contract_test_sha256" => "test/tooling/package_contract_test.rb",
    "work_packet_sha256" => "docs/work_packets/M5.2.md",
    "work_packet_index_sha256" => "docs/work_packets/index.yml",
    "package_smoke_sha256" => "bin/package-smoke",
    "gemspec_sha256" => "hitch-rails.gemspec",
    "version_sha256" => "lib/hitch/version.rb",
    "readme_sha256" => "README.md",
    "public_api_sha256" => "docs/public_api/0.2.0.md",
    "changelog_sha256" => "CHANGELOG.md"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable unpublished M5.2 implementation" do
    assert_equal "hitch.m5.2-tool-generator-evidence.v1", @evidence.fetch("schema")
    assert_equal "M5.2", @evidence.fetch("milestone")
    assert_equal "verified_internal_development", @evidence.fetch("status")
    assert_instance_of Time, Time.iso8601(@evidence.fetch("verified_at"))
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_before_acceptance")
    assert_equal true, @source.fetch("acceptance_commands_ran_against_source_commit")

    commit = @source.fetch("commit")
    assert_equal @source.fetch("tree"), git!("rev-parse", "#{commit}^{tree}").strip
    assert_equal @source.fetch("predecessor_commit"), git!("rev-parse", "#{commit}^").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"), 'VERSION = "0.2.0.pre.4.dev"'

    artifact = @evidence.fetch("artifact")
    assert_equal [ "0.2.0.pre.4.dev", "0.2.0.pre.4", "public_optional" ],
      artifact.values_at("version", "target_checkpoint", "distribution")
    assert_equal [ false, false, false, false, false, false ], artifact.values_at(
      "checkpoint_sealed",
      "public_eligible",
      "published",
      "tag_created",
      "github_release_created",
      "rubygems_publication_performed"
    )
    assert_equal "deferred_until_M5.4_or_final_0.2.0", artifact.fetch("publication_decision")
  end

  test "checksums bind generator helper package and documentation bytes to the implementation commit" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "Lattice evidence accounts for every generated and refused row" do
    schema = source_json("test/lattice/tool_generator.json")
    scenarios = source_json("test/lattice/tool_generator_scenarios.json")
    lattice = @evidence.fetch("lattice")

    assert_equal lattice.fetch("model"), schema.fetch("model_name")
    assert_equal [ 42, 2, 31, 180 ], [
      scenarios.dig("meta", "seed"),
      scenarios.dig("meta", "strength"),
      scenarios.dig("meta", "test_count"),
      scenarios.dig("meta", "exhaustive_count")
    ]
    rows = scenarios.fetch("scenarios")
    successful = rows.count do |row|
      values = row.fetch("values")
      values.fetch("name") != "invalid" &&
        values.fetch("namespace") != "invalid" &&
        values.fetch("collision") == "none"
    end
    assert_equal (1..31).to_a, rows.map { |row| row.fetch("id") }
    assert_equal [ 31, 4, 27, 100.0 ], lattice.values_at(
      "scenario_rows",
      "successful_rows",
      "refused_rows",
      "pairwise_coverage_percent"
    )
    assert_equal successful, lattice.fetch("successful_rows")
    assert_equal rows.length - successful, lattice.fetch("refused_rows")
    assert_equal schema.fetch("parameters").fetch(3).fetch("values").drop(1),
      lattice.fetch("collision_values")
    assert_equal schema.fetch("parameters").fetch(2).fetch("values"), lattice.fetch("registry_values")
    assert_equal 4, schema.fetch("constraints").count { |constraint| constraint.fetch("type") == "forced" }
    assert_equal true, lattice.fetch("refused_row_host_snapshots_unchanged")
  end

  test "normalization output and rollback manifests are exact" do
    normalization = @evidence.fetch("normalization")
    assert_equal 64, normalization.fetch("maximum_mcp_name_characters")
    cases = normalization.fetch("cases").map do |entry|
      entry.values_at("input", "namespace", "canonical_name", "class_name", "tool_name")
    end
    assert_equal [
      [ "weather_lookup", "McpTools", "weather_lookup", "McpTools::WeatherLookup", "weather_lookup" ],
      [ "billing/customer_lookup", "McpTools", "billing/customer_lookup",
        "McpTools::Billing::CustomerLookup", "billing.customer_lookup" ],
      [ "Billing::CustomerLookup", "Admin::McpTools", "billing/customer_lookup",
        "Admin::McpTools::Billing::CustomerLookup", "billing.customer_lookup" ],
      [ "account-summary", "McpTools", "account_summary", "McpTools::AccountSummary", "account_summary" ]
    ], cases
    assert_equal true, normalization.fetch("equivalent_nested_inputs_collide_without_overwrite")

    outputs = @evidence.fetch("generated_outputs")
    assert_generated_output(outputs.fetch("default"), canonical_name: "weather_lookup")
    assert_generated_output(outputs.fetch("custom_nested"), canonical_name: "billing/customer_lookup")

    generated_test = outputs.fetch("generated_minitest")
    test_bytes = render_template("lib/generators/hitch/tool/templates/tool_test.rb.tt", outputs.fetch("default"))
    assert_equal 3, test_bytes.scan(/^  test "/).length
    assert_includes test_bytes, 'require "hitch/mcp/test_helper"'
    assert_equal [ "ActiveSupport::TestCase", true, 3, "passed_with_zero_skips" ],
      generated_test.values_at("framework", "requires_public_helper", "tests", "execution_result")
  end

  test "deny-default registry helper rollback and acceptance claims remain explicit" do
    generator = @evidence.fetch("generator")
    assert_equal [ false, false, false ], generator.values_at(
      "automatic_registration",
      "automatic_registry_creation",
      "automatic_registry_edit"
    )
    assert_equal [ false, true, false, true, false, "raises_Hitch::MCP::Forbidden",
      "raises_until_host_implementation" ], generator.fetch("generated_policy").values_at(
        "read_only_hint",
        "destructive_hint",
        "idempotent_hint",
        "open_world_hint",
        "available_to",
        "authorize",
        "perform"
      )

    helper = @evidence.fetch("public_test_helper")
    assert_equal [ true, true, true, true, true, true, true, true ], helper.values_at(
      "resource_uri_read_on_every_call",
      "default_and_ipv6_authority_normalization",
      "json_inputs_deep_copied",
      "duplicate_normalized_keys_refused",
      "recursive_or_non_json_values_refused",
      "ambiguous_meta_refused",
      "bearer_token_present_only_in_headers",
      "ordinary_integration_response_returned"
    )
    helper_source = git!("show", "#{@source.fetch('commit')}:lib/hitch/mcp/test_helper.rb")
    assert_includes helper_source,
      "def mcp_headers(token:, method:, name: nil, protocol_version: PROTOCOL_VERSION)"
    assert_includes helper_source,
      'def post_mcp(method:, token:, params: {}, id: "hitch-test", client_info: nil,'

    rollback = @evidence.fetch("refusal_and_rollback")
    assert_equal [ true, true, true, true, true, true ], rollback.values_at(
      "preflight_refusals_write_nothing",
      "registry_absent_stays_absent",
      "registry_present_bytes_unchanged",
      "exact_rollback_removed_only_generated_tool_test_and_manifest",
      "rollback_refuses_while_exact_registration_line_remains",
      "all_rollback_refusals_write_nothing"
    )
    assert_equal [ 1, 2, 5, 1 ], rollback.values_at(
      "exact_rollback_cases",
      "customized_file_refusal_cases",
      "structurally_invalid_manifest_refusal_cases",
      "registered_instruction_refusal_cases"
    )

    acceptance = @evidence.fetch("acceptance")
    assert_equal [ "bin/ci-generators tool", @source.fetch("commit"), 31, 15, 273, 0, 0, 0 ],
      acceptance.fetch("generator").values_at(
        "command", "source_commit", "lattice_rows", "runs", "assertions",
        "failures", "errors", "skips"
      )
    assert_equal [ "bin/contract", @source.fetch("commit"), 49, 896, 12, 13, 121, 3657, 0, 0, 0 ],
      acceptance.fetch("contract").values_at(
        "command", "source_commit", "verification_runs", "verification_assertions",
        "scenario_rows", "forced_suites", "runtime_runs", "runtime_assertions",
        "failures", "errors", "skips"
      )
    assert_equal [ "bin/rubocop", @source.fetch("commit"), 198, 0 ],
      acceptance.fetch("rubocop").values_at("command", "source_commit", "files", "offenses")

    package = acceptance.fetch("package_smoke")
    assert_equal @source.fetch("tree"), package.fetch("source_tree")
    assert_equal [ "rails_7_2_sqlite", "rails_8_1_postgresql" ],
      package.fetch("profiles").map { |profile| profile.fetch("name") }
    assert package.fetch("profiles").all? do |profile|
      profile.fetch("auth_migrations_mcp_install_tool_generator_boot_oauth_registry") == "passed"
    end
    assert_equal false, package.fetch("published")
  end

  test "evidence contains no credentials request data host records or raw logs" do
    assert_equal false, @evidence.fetch("contains_credentials")
    assert_equal false, @evidence.fetch("contains_request_bodies")
    assert_equal false, @evidence.fetch("contains_host_records")
    assert_equal false, @evidence.fetch("contains_raw_process_logs")
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
  end

  private

  def assert_generated_output(output, canonical_name:)
    tool_bytes = render_template("lib/generators/hitch/tool/templates/tool.rb.tt", output)
    test_bytes = render_template("lib/generators/hitch/tool/templates/tool_test.rb.tt", output)
    assert_equal Digest::SHA256.hexdigest(tool_bytes), output.dig("files", 0, "sha256")
    assert_equal Digest::SHA256.hexdigest(test_bytes), output.dig("files", 1, "sha256")

    manifest = {
      "schema_version" => 1,
      "generator" => "hitch:tool",
      "canonical_name" => canonical_name,
      "namespace" => output.fetch("namespace"),
      "class_name" => output.fetch("class_name"),
      "tool_name" => output.fetch("tool_name"),
      "files" => output.fetch("files"),
      "registry_instruction" => output.fetch("registration_line"),
      "rollback_command" => output.fetch("rollback_command")
    }
    manifest_bytes = "#{JSON.pretty_generate(manifest)}\n"
    assert_equal Digest::SHA256.hexdigest(manifest_bytes), output.dig("manifest", "sha256")
  end

  def render_template(path, output)
    context = Object.new
    class_name = output.fetch("class_name")
    context.instance_variable_set(:@class_name, class_name)
    context.instance_variable_set(:@test_class_name, "#{class_name}Test")
    context.instance_variable_set(:@class_modules, class_name.split("::")[0...-1])
    context.instance_variable_set(:@class_leaf, class_name.split("::").last)
    context.instance_variable_set(:@tool_name, output.fetch("tool_name"))
    template = git!("show", "#{@source.fetch('commit')}:#{path}")
    ERB.new(template, trim_mode: "-").result(context.instance_eval { binding })
  end

  def source_json(path)
    JSON.parse(git!("show", "#{@source.fetch('commit')}:#{path}"))
  end

  def git!(*arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: REPOSITORY_ROOT.to_s)
    assert_predicate status, :success?, stderr
    stdout
  end

  def git_status(*arguments)
    _stdout, _stderr, status = Open3.capture3("git", *arguments, chdir: REPOSITORY_ROOT.to_s)
    status
  end
end
