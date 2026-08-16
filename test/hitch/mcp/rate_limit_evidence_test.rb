# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "time"
require "yaml"

# The M4.3 admission-store erratum reopened this record. Until `bin/ci-rate-limit`
# regenerates it against the host-cache-store design, the evidence file is absent
# by contract — `bin/verify-release-evidence` requires pending evidence to be
# absent, not stale.
#
# The reopened state is asserted below rather than skipped. The full artifact
# contract lives in RateLimitEvidenceContractTest, which defines itself only once
# the regenerated file exists.
class Hitch::MCP::RateLimitEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/rate-limit/cross-process.json")
  INDEX_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/index.json")
  CONTRACT_PATH = REPOSITORY_ROOT.join("docs/contracts/release_evidence.yml")

  test "the ledger and the working tree agree on the record's status" do
    record = JSON.parse(INDEX_PATH.read)
      .fetch("records")
      .find { |entry| entry.fetch("kind") == "rate_limit_cross_process" }
    contract = YAML.safe_load_file(CONTRACT_PATH, permitted_classes: [], aliases: false)

    assert_equal "M4.3", record.fetch("milestone")

    if record.fetch("status") == "pending"
      assert_nil record.fetch("sha256"), "a pending record carries no digest"
      refute_predicate EVIDENCE_PATH, :exist?,
        "pending evidence must be absent rather than stale"
      assert_includes contract.fetch("future_records").keys, "rate_limit_cross_process"
      refute_includes contract.fetch("accepted_records").keys, "rate_limit_cross_process"
    else
      assert_equal "accepted", record.fetch("status")
      assert_predicate EVIDENCE_PATH, :exist?
      assert_equal record.fetch("sha256"), Digest::SHA256.file(EVIDENCE_PATH).hexdigest
    end
  end

  test "the record remains a final prerequisite while it is reopened" do
    _stdout, stderr, status = Open3.capture3(
      REPOSITORY_ROOT.join("bin/verify-release-evidence").to_s,
      "--through", "M8",
      chdir: REPOSITORY_ROOT.to_s
    )

    refute_predicate status, :success?
    assert_kind_of String, stderr
  end
end

if Hitch::MCP::RateLimitEvidenceTest::EVIDENCE_PATH.exist?
  class Hitch::MCP::RateLimitEvidenceContractTest < ActiveSupport::TestCase
    REPOSITORY_ROOT = Hitch::MCP::RateLimitEvidenceTest::REPOSITORY_ROOT
    EVIDENCE_PATH = Hitch::MCP::RateLimitEvidenceTest::EVIDENCE_PATH
    TOOLCHAIN_PATH = REPOSITORY_ROOT.join("test/conformance/toolchain.lock.yml")

    setup do
      @raw_evidence = EVIDENCE_PATH.read
      @evidence = JSON.parse(@raw_evidence)
      @source = @evidence.fetch("source")
    end

    test "evidence resolves to a clean M4.3 implementation commit" do
      assert_equal "hitch.m4.3-rate-limit-cross-process-evidence.v1", @evidence.fetch("schema")
      assert_equal "M4.3", @evidence.fetch("milestone")
      assert_equal "verified_internal_rate_boundary", @evidence.fetch("status")
      assert_instance_of Time, Time.iso8601(@evidence.fetch("verified_at"))
      assert_equal true, @source.fetch("worktree_clean_before_evidence_write")

      commit = @source.fetch("commit")
      tree = @source.fetch("tree")
      assert_match(/\A[0-9a-f]{40}\z/, commit)
      assert_match(/\A[0-9a-f]{40}\z/, tree)
      assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
      assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
      assert_includes git!("show", "#{commit}:bin/ci-rate-limit"),
        "test/integration/mcp_rate_limit_cross_process_contract.rb"
    end

    test "artifact remains an unsealed unpublished internal prerelease candidate" do
      artifact = @evidence.fetch("artifact")
      assert_equal "internal_only", artifact.fetch("distribution")
      assert_equal false, artifact.fetch("published")
      assert_equal false, artifact.fetch("tag_created")
      assert_equal false, artifact.fetch("github_release_created")
      assert_equal false, artifact.fetch("rubygems_publication_performed")
    end

    # Redis is one supported backend exercised by the pinned cross-process lane,
    # not a Hitch dependency. The lane still pins its image by digest.
    test "the pinned backend lane matches the immutable toolchain contract" do
      backend = @evidence.fetch("backend")
      lock = YAML.safe_load_file(TOOLCHAIN_PATH, permitted_classes: [], aliases: false).fetch("redis")

      assert_equal "ActiveSupport::Cache::RedisCacheStore", backend.fetch("store_class")
      assert_equal lock.fetch("image"), backend.fetch("image")
      assert_equal lock.fetch("index_digest"), backend.fetch("index_digest")

      platform_digest_key = {
        "linux/amd64" => "linux_amd64_digest",
        "linux/arm64" => "linux_arm64_digest"
      }.fetch(backend.fetch("platform"))
      assert_equal lock.fetch(platform_digest_key), backend.fetch("platform_digest")
      repository = backend.fetch("image").sub(/:[^\/:]+\z/, "")
      assert_equal "#{repository}@#{backend.fetch('platform_digest')}", backend.fetch("pulled_reference")
      assert_match(/\A[0-9a-f]{12}\z/, backend.fetch("container_id"))
      assert_equal "7.4.5", backend.fetch("server_version")
    end

    test "contract fixes shared HMAC admission and terminal behavior" do
      contract = @evidence.fetch("contract")
      assert_equal "fixed_window", contract.fetch("algorithm")
      assert_includes contract.fetch("identity"), "HMAC-SHA256"
      assert_equal false, contract.fetch("bearer_token_in_key")
      assert_equal false, contract.fetch("raw_identifiers_in_key")
      assert_equal "host ActiveSupport::Cache store increment with first-write expiry",
        contract.fetch("increment_and_first_expiry")
      assert_equal %w[server/discover tools/list tools/call], contract.fetch("shared_methods")
      assert_equal 200, contract.fetch("exact_limit_status")
      assert_equal 429, contract.fetch("exceeded_status")
      assert_equal "conservative window seconds", contract.fetch("retry_after")
      assert_equal 503, contract.fetch("store_error_status")
      assert_equal "admits_fail_open_documented", contract.fetch("nil_count")
      assert_equal 0, contract.fetch("store_error_downstream_body_registry_sdk_host_calls")
      assert_equal "boot_refused", contract.fetch("production_unshared_store")
      assert_equal false, contract.fetch("runtime_redis_dependency")
    end

    test "both Rails adapters prove one exact cross-process fixed window" do
      lanes = @evidence.fetch("lanes")
      assert_equal %w[postgresql sqlite3], lanes.map { |lane| lane.fetch("adapter") }.sort
      assert_equal 2, lanes.map { |lane| lane.fetch("key_digest") }.uniq.length

      lanes.each do |lane|
        assert_equal 1, lane.fetch("schema_version")
        assert_match(/\A(?:7\.2|8\.1)\./, lane.fetch("rails_version"))
        assert_equal 4, lane.fetch("process_count")
        assert_equal 5, lane.fetch("calls_per_process")
        assert_equal 20, lane.fetch("total_requests")
        assert_equal 12, lane.fetch("configured_limit")
        assert_equal 30, lane.fetch("configured_window_seconds")
        assert_equal 12, lane.fetch("allowed")
        assert_equal 8, lane.fetch("rejected")
        assert_equal 20, lane.fetch("store_count")
        assert_match(/\A[0-9a-f]{64}\z/, lane.fetch("key_digest"))

        outcomes = lane.fetch("process_outcomes")
        assert_equal 4, outcomes.length
        assert outcomes.all? { |outcome| outcome.fetch("calls") == 5 }
        assert outcomes.all? do |outcome|
          outcome.fetch("allowed") + outcome.fetch("rejected") == outcome.fetch("calls")
        end
        assert_equal 12, outcomes.sum { |outcome| outcome.fetch("allowed") }
        assert_equal 8, outcomes.sum { |outcome| outcome.fetch("rejected") }

        # The window expires relative to its first write, so a third increment
        # past the window resets the counter instead of continuing it.
        expiry = lane.fetch("first_expiry_probe")
        assert_equal 1_200, expiry.fetch("window_ms")
        assert_equal [ 1, 2, 1 ], expiry.fetch("counts")
        assert_operator expiry.fetch("elapsed_ms_at_reset"), :>, expiry.fetch("window_ms")
        assert_equal false, expiry.fetch("expiry_rewritten")

        summary = lane.fetch("test_summary")
        assert_operator summary.fetch("runs"), :>=, 27
        assert_operator summary.fetch("assertions"), :positive?
        assert_equal [ 0, 0, 0 ], summary.values_at("failures", "errors", "skips")
      end
    end

    test "evidence contains digests rather than tokens or raw synthetic identities" do
      refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
      refute_match(%r{redis://127\.0\.0\.1:\d+}, @raw_evidence)
      refute_match(/cross-process-[0-9a-f]+@example\.test|cross-process-client-[0-9a-f]+/, @raw_evidence)
    end

    private

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
end
