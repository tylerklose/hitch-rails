# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"

class Hitch::MCPInstallEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/generators/mcp-install.json")
  SOURCE_FILES = {
    "generator_sha256" => "lib/generators/hitch/mcp/install_generator.rb",
    "controller_template_sha256" => "lib/generators/hitch/mcp/templates/controller.rb.tt",
    "initializer_template_sha256" => "lib/generators/hitch/mcp/templates/initializer.rb.tt",
    "registry_template_sha256" => "lib/generators/hitch/mcp/templates/registry.rb.tt",
    "generator_test_sha256" => "test/hitch/mcp_install_generator_test.rb",
    "lattice_schema_sha256" => "test/lattice/mcp_install_generator.json",
    "lattice_scenarios_sha256" => "test/lattice/mcp_install_generator_scenarios.json",
    "generator_runner_sha256" => "bin/ci-generators",
    "generator_dispatch_test_sha256" => "test/tooling/ci_generators_dispatch_test.rb",
    "package_contract_test_sha256" => "test/tooling/package_contract_test.rb",
    "work_packet_sha256" => "docs/work_packets/M5.1.md",
    "work_packet_index_sha256" => "docs/work_packets/index.yml",
    "package_smoke_sha256" => "bin/package-smoke",
    "gemspec_sha256" => "hitch-rails.gemspec",
    "version_sha256" => "lib/hitch/version.rb",
    "readme_sha256" => "README.md",
    "public_api_sha256" => "docs/public_api/0.2.0.md",
    "removing_sha256" => "docs/removing.md"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable unpublished M5.1 implementation" do
    assert_equal "hitch.m5.1-mcp-install-evidence.v1", @evidence.fetch("schema")
    assert_equal "M5.1", @evidence.fetch("milestone")
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

  test "checksums bind generator package and documentation bytes to the implementation commit" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "Lattice evidence accounts for every generated and refused row" do
    schema = source_json("test/lattice/mcp_install_generator.json")
    scenarios = source_json("test/lattice/mcp_install_generator_scenarios.json")
    lattice = @evidence.fetch("lattice")

    assert_equal lattice.fetch("model"), schema.fetch("model_name")
    assert_equal [ 42, 2, 25, 72 ], [
      scenarios.dig("meta", "seed"),
      scenarios.dig("meta", "strength"),
      scenarios.dig("meta", "test_count"),
      scenarios.dig("meta", "exhaustive_count")
    ]
    rows = scenarios.fetch("scenarios")
    successful = rows.count do |row|
      values = row.fetch("values")
      values.fetch("prerequisite") == "complete" &&
        values.fetch("controller_name") != "invalid" &&
        values.fetch("collision") == "none"
    end
    assert_equal (1..25).to_a, rows.map { |row| row.fetch("id") }
    assert_equal [ 25, 2, 23, 100.0 ], lattice.values_at(
      "scenario_rows",
      "successful_rows",
      "refused_rows",
      "pairwise_coverage_percent"
    )
    assert_equal successful, lattice.fetch("successful_rows")
    assert_equal rows.length - successful, lattice.fetch("refused_rows")
    assert_equal schema.fetch("parameters").fetch(2).fetch("values").drop(1),
      lattice.fetch("collision_values")
    assert_equal true, lattice.fetch("refused_row_host_snapshots_unchanged")
  end

  test "generated output hashes describe the exact default and namespaced hosts" do
    outputs = @evidence.fetch("generated_outputs")
    default = outputs.fetch("default")
    custom = outputs.fetch("custom")
    registry = git!("show", "#{@source.fetch('commit')}:lib/generators/hitch/mcp/templates/registry.rb.tt")
    initializer = git!("show", "#{@source.fetch('commit')}:lib/generators/hitch/mcp/templates/initializer.rb.tt")

    assert_equal Digest::SHA256.hexdigest(default_controller), default.dig("files", 0, "sha256")
    assert_equal Digest::SHA256.hexdigest(registry), default.dig("files", 1, "sha256")
    assert_equal Digest::SHA256.hexdigest(initializer), default.dig("files", 2, "sha256")
    assert_equal Digest::SHA256.hexdigest(custom_controller), custom.dig("controller", "sha256")
    assert_equal "admin/mcp#handle", custom.fetch("route_target")

    manifest = {
      "schema_version" => 1,
      "generator" => "hitch:mcp:install",
      "controller_name" => default.fetch("controller_name"),
      "files" => default.fetch("files"),
      "route" => default.fetch("route"),
      "rollback_command" => "bin/rails destroy hitch:mcp:install"
    }
    manifest_bytes = "#{JSON.pretty_generate(manifest)}\n"
    assert_equal Digest::SHA256.hexdigest(manifest_bytes), default.dig("manifest", "sha256")
    assert_equal "mount Hitch::Engine", default.dig("route", "must_precede")
  end

  test "refusal rollback and acceptance results stay explicit and zero-skip" do
    rollback = @evidence.fetch("refusal_and_rollback")
    assert_equal true, rollback.fetch("preflight_refusals_write_nothing")
    assert_equal true, rollback.fetch("exact_rollback_removed_only_generated_files_and_route_block")
    assert_equal true, rollback.fetch("unrelated_route_preserved")
    assert_equal true, rollback.fetch("all_rollback_refusals_write_nothing")
    assert_equal [ 1, 4, 6 ], rollback.values_at(
      "exact_rollback_cases",
      "customized_artifact_refusal_cases",
      "structurally_invalid_manifest_refusal_cases"
    )

    generator = @evidence.dig("acceptance", "generator")
    assert_equal [ "bin/ci-generators install", @source.fetch("commit"), 25, 8, 177, 0, 0, 0 ],
      generator.values_at(
        "command", "source_commit", "lattice_rows", "runs", "assertions",
        "failures", "errors", "skips"
      )
    contract = @evidence.dig("acceptance", "contract")
    assert_equal [ "bin/contract", @source.fetch("commit"), 49, 893, 12, 13, 121, 3657, 0, 0, 0 ],
      contract.values_at(
        "command", "source_commit", "verification_runs", "verification_assertions",
        "scenario_rows", "forced_suites", "runtime_runs", "runtime_assertions",
        "failures", "errors", "skips"
      )
    assert_equal [ "bin/rubocop", @source.fetch("commit"), 193, 0 ],
      @evidence.dig("acceptance", "rubocop").values_at("command", "source_commit", "files", "offenses")

    package = @evidence.dig("acceptance", "package_smoke")
    assert_equal @source.fetch("tree"), package.fetch("source_tree")
    assert_equal [ "rails_7_2_sqlite", "rails_8_1_postgresql" ],
      package.fetch("profiles").map { |profile| profile.fetch("name") }
    assert package.fetch("profiles").all? do |profile|
      profile.fetch("auth_migrations_mcp_generator_boot_oauth_registry") == "passed"
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

  def source_json(path)
    JSON.parse(git!("show", "#{@source.fetch('commit')}:#{path}"))
  end

  def default_controller
    <<~RUBY
      # frozen_string_literal: true

      class McpController < ActionController::API
        include Hitch::MCP::Endpoint
      end
    RUBY
  end

  def custom_controller
    <<~RUBY
      # frozen_string_literal: true

      module Admin
        class McpController < ActionController::API
          include Hitch::MCP::Endpoint
        end
      end
    RUBY
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
