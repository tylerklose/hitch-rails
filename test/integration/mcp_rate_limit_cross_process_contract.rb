# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "fileutils"
require "json"
require "redis"
require "securerandom"
require "timeout"
require "tmpdir"

class MCPRateLimitCrossProcessContractTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ROOT = File.expand_path("../..", __dir__)
  PROCESS_CLIENT = File.join(ROOT, "test/support/mcp_rate_limit_process_client.rb")
  PROCESS_COUNT = Integer(ENV.fetch("HITCH_RATE_LIMIT_PROCESS_COUNT", "4"), 10)
  CALLS_PER_PROCESS = Integer(ENV.fetch("HITCH_RATE_LIMIT_CALLS", "5"), 10)
  REQUEST_LIMIT = Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_TO", "12"), 10)
  WINDOW_SECONDS = Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_WITHIN", "30"), 10)

  setup do
    @redis_url = ENV.fetch("HITCH_MCP_REDIS_URL")
    @evidence_path = ENV.fetch("HITCH_RATE_LIMIT_LANE_EVIDENCE")
    raise "cross-process counts must be positive" unless
      [ PROCESS_COUNT, CALLS_PER_PROCESS, REQUEST_LIMIT, WINDOW_SECONDS ].all?(&:positive?)
    raise "cross-process request total must exceed the limit" unless
      PROCESS_COUNT * CALLS_PER_PROCESS > REQUEST_LIMIT
    configure_runtime
    assert_equal({ to: REQUEST_LIMIT, within: WINDOW_SECONDS }, Hitch.configuration.mcp.request_limit)

    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    @user = User.create!(email: "cross-process-#{SecureRandom.hex(6)}@example.test")
    @client_id = "cross-process-client-#{SecureRandom.hex(8)}"
    @token = mint_token(@user, client_id: @client_id)
  end

  teardown do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
  end

  test "one window is exact across independent Rails processes" do
    results = run_processes
    statuses = results.flat_map { |result| result.fetch("statuses") }
    allowed = statuses.count(200)
    rejected = statuses.count(429)
    expected_total = PROCESS_COUNT * CALLS_PER_PROCESS

    assert_equal expected_total, statuses.length
    assert_equal [ 200, 429 ], statuses.uniq.sort
    assert_equal REQUEST_LIMIT, allowed
    assert_equal expected_total - REQUEST_LIMIT, rejected
    assert results.all? { |result| result.fetch("retry_after").all? { |value| value == WINDOW_SECONDS.to_s } }

    rate_key = Hitch::MCP.const_get(:RateLimitKey, false).call(
      principal: @user,
      client_id: @client_id
    )
    redis = Redis.new(url: @redis_url, timeout: 1.0, connect_timeout: 1.0, reconnect_attempts: 0)
    count = Integer(redis.get(rate_key), 10)
    ttl_ms = redis.pttl(rate_key)
    assert_equal expected_total, count
    assert_operator ttl_ms, :positive?
    assert_operator ttl_ms, :<=, WINDOW_SECONDS * 1_000

    first_expiry = verify_first_expiry
    elapsed_ms = results.map { |result| result.fetch("elapsed_ms") }.max
    evidence = {
      schema_version: 1,
      adapter: ActiveRecord::Base.connection_db_config.adapter,
      rails_version: Rails.version,
      process_count: PROCESS_COUNT,
      calls_per_process: CALLS_PER_PROCESS,
      total_requests: expected_total,
      configured_limit: REQUEST_LIMIT,
      configured_window_seconds: WINDOW_SECONDS,
      allowed:,
      rejected:,
      store_count: count,
      ttl_ms: ttl_ms,
      max_process_elapsed_ms: elapsed_ms,
      key_digest: rate_key.delete_prefix("hitch:mcp:rate-limit:v1:"),
      process_outcomes: results.map do |result|
        {
          calls: result.fetch("calls"),
          allowed: result.fetch("statuses").count(200),
          rejected: result.fetch("statuses").count(429),
          elapsed_ms: result.fetch("elapsed_ms")
        }
      end,
      first_expiry_probe: first_expiry
    }
    FileUtils.mkdir_p(File.dirname(@evidence_path))
    File.write(@evidence_path, JSON.pretty_generate(evidence) + "\n")
  ensure
    redis&.close
  end

  private

  def configure_runtime
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.allowed_hosts = []
      configuration.allowed_origins = []
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = { name: "hitch-cross-process", version: "0.2.0" }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to: REQUEST_LIMIT, within: WINDOW_SECONDS }
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::RedisCacheStore.new(url: @redis_url)
    end
    Hitch.configuration.validate!
  end

  def run_processes
    Dir.mktmpdir("hitch-rate-limit-processes-") do |directory|
      token_path = File.join(directory, "bearer")
      gate_path = File.join(directory, "gate")
      File.open(token_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(@token)
      end

      pids = []
      process_files = PROCESS_COUNT.times.map do |index|
        ready_path = File.join(directory, "ready-#{index}")
        result_path = File.join(directory, "result-#{index}.json")
        output_path = File.join(directory, "process-#{index}.log")
        environment = {
          "HITCH_RATE_LIMIT_GATE_FILE" => gate_path,
          "HITCH_RATE_LIMIT_READY_FILE" => ready_path,
          "HITCH_RATE_LIMIT_RESULT_FILE" => result_path,
          "HITCH_RATE_LIMIT_TOKEN_FILE" => token_path,
          "HITCH_RATE_LIMIT_CALLS" => CALLS_PER_PROCESS.to_s
        }
        pid = Process.spawn(
          environment,
          File.join(ROOT, "bin/rails"),
          "runner",
          PROCESS_CLIENT,
          chdir: ROOT,
          out: output_path,
          err: [ :child, :out ]
        )
        pids << pid
        { ready: ready_path, result: result_path, output: output_path, pid: }
      end

      wait_for_ready!(process_files)
      File.write(gate_path, "go")
      statuses = Timeout.timeout(60) do
        process_files.to_h do |entry|
          [ entry.fetch(:pid), Process.wait2(entry.fetch(:pid)).last ]
        end
      end
      pids.clear
      failures = process_files.reject { |entry| statuses.fetch(entry.fetch(:pid)).success? }
      unless failures.empty?
        messages = failures.map do |entry|
          "pid=#{entry.fetch(:pid)} output=#{File.read(entry.fetch(:output))}"
        end
        flunk "cross-process clients failed: #{messages.join(' | ')}"
      end

      process_files.map { |entry| JSON.parse(File.read(entry.fetch(:result))) }
    ensure
      pids.each do |pid|
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def wait_for_ready!(process_files)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until process_files.all? { |entry| File.exist?(entry.fetch(:ready)) }
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        outputs = process_files.map do |entry|
          File.exist?(entry.fetch(:output)) ? File.read(entry.fetch(:output)) : "missing output"
        end
        flunk "timed out waiting for cross-process clients: #{outputs.join(' | ')}"
      end
      sleep 0.02
    end
  end

  # A fixed window must expire relative to its first write, not its most recent
  # one. RedisCacheStore#increment issues EXPIRE ... NX for exactly that reason;
  # this proves the behavior rather than the implementation, so any supported
  # backend can be swapped in.
  #
  # Increments land at t=0, t=0.9, and t=1.4 against a 1.2s window. The third
  # falls outside the window opened at t=0 but inside one that a rewritten
  # expiry would have opened at t=0.9, so a reset to 1 distinguishes them.
  def verify_first_expiry
    store = ActiveSupport::Cache::RedisCacheStore.new(url: @redis_url)
    key = "hitch:mcp:rate-limit:v1:probe:#{SecureRandom.hex(32)}"
    first = store.increment(key, 1, expires_in: 1.2)
    sleep 0.9
    second = store.increment(key, 1, expires_in: 1.2)
    sleep 0.5
    third = store.increment(key, 1, expires_in: 1.2)

    assert_equal 1, first
    assert_equal 2, second
    assert_equal 1, third,
      "the window expired relative to its most recent write, not its first"
    {
      window_ms: 1_200,
      counts: [ first, second, third ],
      elapsed_ms_at_reset: 1_400,
      expiry_rewritten: false
    }
  ensure
    begin
      store&.delete(key)
    rescue StandardError
      nil
    end
  end

  def mint_token(principal, client_id:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    authorization = Hitch::AccessToken.create_authorization!(
      principal:,
      client_id:,
      client_name: "Cross-process Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes: "mcp",
      resource_uri: "https://dummy.test/mcp"
    )
    exchange_authorization_code(authorization, verifier:)
  end
end
