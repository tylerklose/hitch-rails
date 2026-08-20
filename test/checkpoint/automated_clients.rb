# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "securerandom"
require "socket"
require "timeout"
require "uri"
require "yaml"

require_relative "pinned_redis"

module HitchCheckpoint
  # M5.4-only acceptance harness. It is deliberately under test/ so none of
  # this client automation or its credential bridge can enter the gem.
  class AutomatedClients
    PROTOCOL_VERSION = "2026-07-28"
    MATRIX_PATH = "test/lattice/m5_automated_clients_scenarios.json"
    LOCK_PATH = "test/conformance/toolchain.lock.yml"
    SERVER_READY_SECONDS = 30
    CLIENT_TIMEOUT_SECONDS = 90

    class CommandFailed < StandardError; end
    class CommandTimedOut < StandardError; end

    def self.open(root:, working_directory:)
      PinnedRedis.open(root:) do |redis|
        yield new(root:, working_directory:, redis:)
      end
    end

    def initialize(root:, working_directory:, redis:)
      @root = File.expand_path(root)
      @working_directory = File.expand_path(working_directory)
      @redis = redis
      @lock = YAML.safe_load_file(File.join(@root, LOCK_PATH), permitted_classes: [], aliases: false)
      @client_lock = @lock.fetch("automated_clients")
      @scenarios = load_scenarios
      @runtime = prepare_runtime
    end

    attr_reader :runtime

    def host_environment(resource_uri:)
      {
        "HITCH_MCP_RESOURCE_URI" => resource_uri,
        "HITCH_MCP_REDIS_URL" => @redis.url
      }
    end

    def evidence
      {
        "typescript" => runtime.fetch("typescript").except("executable"),
        "python" => runtime.fetch("python").except("python", "executable"),
        "matrix" => runtime.fetch("matrix"),
        "redis" => @redis.evidence
      }
    end

    def run(app:, profile_name:, environment:)
      scenarios = @scenarios.select { |scenario| scenario.dig("values", "database") == profile_name }
      raise "automated client matrix has no #{profile_name} scenarios" unless scenarios.length == 4

      port = available_port
      base_url = "http://127.0.0.1:#{port}"
      server_environment = environment.merge(host_environment(resource_uri: "#{base_url}/mcp"))
      write_host_fixture(app)
      credentials = create_clients(
        app:,
        profile_name:,
        scenarios:,
        environment: server_environment,
        issuer: base_url
      )

      with_server(app:, port:, environment: server_environment) do
        scenarios.map do |scenario|
          values = scenario.fetch("values")
          scenario_name = [ profile_name, values.fetch("sdk"), values.fetch("oauth_client") ].join(":")
          credential = credentials.fetch(scenario_name)
          run_client(
            values.fetch("sdk"),
            credential.merge(
              "scenario" => scenario_name,
              "endpoint" => "#{base_url}/mcp",
              "issuer" => base_url,
              "redirect_uri" => credential.fetch("redirect_uri")
            )
          ).merge(
            "matrix_id" => scenario.fetch("id"),
            "database" => profile_name
          )
        end
      end
    end

    private

    def load_scenarios
      document = JSON.parse(File.read(File.join(@root, MATRIX_PATH)))
      meta = document.fetch("meta")
      unless meta.values_at("strength", "test_count", "exhaustive_count", "seed") == [ 3, 8, 8, 42 ]
        raise "automated client matrix is not the exhaustive locked 2x2x2 set"
      end

      scenarios = document.fetch("scenarios")
      actual = scenarios.map do |scenario|
        values = scenario.fetch("values")
        [ values.fetch("database"), values.fetch("sdk"), values.fetch("oauth_client") ]
      end.sort
      expected = %w[rails_7_2_sqlite rails_8_1_postgresql].product(
        %w[typescript python],
        %w[public confidential]
      ).sort
      raise "automated client matrix combinations drifted" unless actual == expected

      scenarios.freeze
    end

    def prepare_runtime
      typescript = prepare_typescript
      python = prepare_python
      {
        "typescript" => typescript,
        "python" => python,
        "matrix" => {
          "path" => MATRIX_PATH,
          "sha256" => Digest::SHA256.file(File.join(@root, MATRIX_PATH)).hexdigest,
          "rows" => 8,
          "strength" => 3,
          "seed" => 42
        }
      }.freeze
    end

    def prepare_typescript
      lock = @client_lock.fetch("typescript")
      directory = File.join(@working_directory, "typescript-client")
      FileUtils.mkdir_p(directory)
      %w[package_manifest package_lock fixture].each do |key|
        source = File.join(@root, lock.dig(key, "path"))
        verify_checksum!(source, lock.dig(key, "sha256"), "TypeScript #{key}")
        FileUtils.cp(source, File.join(directory, File.basename(source)))
      end

      capture!("npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", chdir: directory,
        timeout_seconds: 180)
      installed_manifest = File.join(directory, "node_modules/@modelcontextprotocol/client/package.json")
      version = JSON.parse(File.read(installed_manifest)).fetch("version")
      raise "official TypeScript MCP client version drifted: #{version}" unless version == lock.fetch("version").to_s

      {
        "package" => lock.fetch("package"),
        "version" => version,
        "artifact" => lock.fetch("artifact"),
        "integrity" => lock.fetch("integrity"),
        "package_lock_sha256" => lock.dig("package_lock", "sha256"),
        "fixture_sha256" => lock.dig("fixture", "sha256"),
        "executable" => File.join(directory, File.basename(lock.dig("fixture", "path")))
      }.freeze
    end

    def prepare_python
      lock = @client_lock.fetch("python")
      directory = File.join(@working_directory, "python-client")
      wheelhouse = File.join(directory, "wheelhouse")
      FileUtils.mkdir_p(wheelhouse)
      requirements = File.join(@root, lock.dig("requirements_lock", "path"))
      fixture = File.join(@root, lock.dig("fixture", "path"))
      verify_checksum!(requirements, lock.dig("requirements_lock", "sha256"), "Python requirements")
      verify_checksum!(fixture, lock.dig("fixture", "sha256"), "Python fixture")

      python = ENV.fetch("HITCH_PYTHON", "python3")
      capture!(python, "-m", "venv", File.join(directory, "venv"), timeout_seconds: 120)
      venv_python = File.join(directory, "venv/bin/python")
      capture!(
        venv_python, "-m", "pip", "download",
        "--disable-pip-version-check", "--only-binary=:all:", "--require-hashes",
        "--dest", wheelhouse, "--requirement", requirements,
        timeout_seconds: 240
      )
      wheel = Dir[File.join(wheelhouse, "mcp-#{lock.fetch('version')}-*.whl")]
      raise "official Python MCP wheel download was ambiguous" unless wheel.one?
      verify_checksum!(wheel.first, lock.fetch("sha256"), "Python MCP wheel")

      capture!(
        venv_python, "-m", "pip", "install",
        "--disable-pip-version-check", "--no-index", "--find-links", wheelhouse,
        "--only-binary=:all:", "--require-hashes",
        "--requirement", requirements,
        timeout_seconds: 240
      )
      version = capture!(
        venv_python, "-c", "import importlib.metadata; print(importlib.metadata.version('mcp'))"
      ).strip
      raise "official Python MCP client version drifted: #{version}" unless version == lock.fetch("version").to_s

      {
        "package" => lock.fetch("package"),
        "version" => version,
        "artifact" => lock.fetch("artifact"),
        "wheel_sha256" => Digest::SHA256.file(wheel.first).hexdigest,
        "requirements_sha256" => lock.dig("requirements_lock", "sha256"),
        "requirements_hashes" => "required",
        "install_source" => "verified_offline_wheelhouse",
        "fixture_sha256" => lock.dig("fixture", "sha256"),
        "python" => venv_python,
        "executable" => fixture
      }.freeze
    end

    def write_host_fixture(app)
      File.write(File.join(app, "app/controllers/application_controller.rb"), <<~RUBY)
        # frozen_string_literal: true

        class ApplicationController < ActionController::Base
          def current_user
            Hitch::Client.order(:id).first
          end
        end
      RUBY
      File.write(File.join(app, "config/initializers/hitch.rb"), <<~RUBY)
        # frozen_string_literal: true

        Hitch.configure do |config|
          config.resource_uri = ENV.fetch("HITCH_MCP_RESOURCE_URI")
          config.allowed_hosts = []
          config.allowed_origins = []
          config.brand_name = "Hitch M5 Disposable App"
          config.supported_scopes = %w[mcp admin]
          config.client_id_metadata_enabled = false
          config.dynamic_client_registration_enabled = false
          config.mcp.enabled = true
          config.mcp.registry = "McpToolRegistry"
          config.mcp.server_info = { name: "hitch-m5-smoke", version: "1.0.0" }
          config.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
          config.mcp.request_limit = { to: 1_000, within: 60 }
          config.mcp.rate_limit_store = ActiveSupport::Cache::RedisCacheStore.new(
            url: ENV.fetch("HITCH_MCP_REDIS_URL")
          )
          config.mcp.max_request_bytes = 1.megabyte
          config.mcp.max_result_bytes = 1.megabyte
        end

        Rails.application.config.action_controller.allow_forgery_protection = true
      RUBY

      package_tool_path = File.join(app, "app/tools/mcp_tools/package_echo.rb")
      FileUtils.mkdir_p(File.dirname(package_tool_path))
      File.write(package_tool_path, tool_source(
        class_name: "PackageEcho",
        tool_name: "package.echo",
        result_prefix: "echo"
      ))
      File.write(File.join(app, "app/tools/mcp_tools/admin_echo.rb"), tool_source(
        class_name: "AdminEcho",
        tool_name: "admin.echo",
        result_prefix: "admin"
      ))
      File.write(File.join(app, "app/tools/mcp_tool_registry.rb"), <<~RUBY)
        # frozen_string_literal: true

        class McpToolRegistry < Hitch::MCP::Registry
          register McpTools::PackageEcho, scopes: [ "mcp" ]
          register McpTools::AdminEcho, scopes: %w[mcp admin]
        end
      RUBY
    end

    def tool_source(class_name:, tool_name:, result_prefix:)
      <<~RUBY
        # frozen_string_literal: true

        module McpTools
          class #{class_name} < Hitch::MCP::Tool
            tool_name #{tool_name.dump}
            description "M5 package and official client acceptance tool"
            input_schema(
              type: "object",
              properties: { message: { type: "string" } },
              required: [ "message" ],
              additionalProperties: false
            )

            def self.available_to?(_context) = true
            def self.authorize!(_context, arguments:) = nil

            def self.perform(_context, arguments:)
              Hitch::MCP::Result.text(#{result_prefix.dump} + ":" + arguments.fetch("message"))
            end
          end
        end
      RUBY
    end

    def create_clients(app:, profile_name:, scenarios:, environment:, issuer:)
      public_scenarios = scenarios.filter_map do |scenario|
        values = scenario.fetch("values")
        next unless values.fetch("oauth_client") == "public"

        client_attributes(profile_name:, scenario:, values:)
      end
      credentials = create_public_clients(app:, scenarios: public_scenarios, environment:)
      rotations = []
      scenarios.each do |scenario|
        values = scenario.fetch("values")
        next unless values.fetch("oauth_client") == "confidential"

        attributes = client_attributes(profile_name:, scenario:, values:)
        original = run_client_credential_task(
          app:,
          task: "hitch:clients:create_confidential",
          environment: environment.merge(
            "CLIENT_ID" => attributes.fetch("client_id"),
            "NAME" => attributes.fetch("scenario"),
            "REDIRECT_URI" => attributes.fetch("redirect_uri")
          )
        )
        rotated = run_client_credential_task(
          app:,
          task: "hitch:clients:rotate_secret",
          environment: environment.merge("CLIENT_ID" => attributes.fetch("client_id"))
        )
        rotations << {
          "client_id" => attributes.fetch("client_id"),
          "old_secret" => original.fetch("client_secret"),
          "new_secret" => rotated.fetch("client_secret")
        }
        credentials[attributes.fetch("scenario")] = {
          "client_id" => attributes.fetch("client_id"),
          "client_secret" => rotated.fetch("client_secret"),
          "auth_method" => "client_secret_basic",
          "redirect_uri" => attributes.fetch("redirect_uri"),
          "issuer" => issuer
        }
      end
      verify_rotations!(app:, rotations:, environment:)
      credentials.transform_values { |value| value.merge("issuer" => issuer) }
    end

    def client_attributes(profile_name:, scenario:, values:)
      {
        "matrix_id" => scenario.fetch("id"),
        "scenario" => [ profile_name, values.fetch("sdk"), values.fetch("oauth_client") ].join(":"),
        "client_id" => "hitch-m5-#{scenario.fetch('id')}",
        "redirect_uri" => "http://127.0.0.1/callback/#{scenario.fetch('id')}"
      }
    end

    def create_public_clients(app:, scenarios:, environment:)
      runner = <<~RUBY
        require "json"

        scenarios = JSON.parse(ENV.fetch("HITCH_CLIENT_SCENARIOS"))
        credentials = scenarios.to_h do |scenario|
          name = scenario.fetch("scenario")
          client = Hitch::Client.register!(
            client_id: scenario.fetch("client_id"),
            client_name: name,
            redirect_uris: [ scenario.fetch("redirect_uri") ]
          )
          [ name, {
            "client_id" => client.client_id,
            "client_secret" => nil,
            "auth_method" => "none",
            "redirect_uri" => scenario.fetch("redirect_uri")
          } ]
        end
        puts "HITCH_PUBLIC_CLIENTS=" + JSON.generate(credentials)
      RUBY
      output = capture!(
        "bundle", "exec", "rails", "runner", runner,
        environment: environment.merge("HITCH_CLIENT_SCENARIOS" => JSON.generate(scenarios)),
        chdir: app,
        timeout_seconds: 90
      )
      marker = output.lines.reverse.find { |line| line.start_with?("HITCH_PUBLIC_CLIENTS=") }
      raise "public client provisioning did not report its result" unless marker

      JSON.parse(marker.delete_prefix("HITCH_PUBLIC_CLIENTS="))
    end

    def run_client_credential_task(app:, task:, environment:)
      output_path = File.join(@working_directory, "credential-#{SecureRandom.hex(8)}")
      output = capture!(
        "bin/rails", task,
        environment: environment.merge("OUTPUT_FILE" => output_path),
        chdir: app,
        timeout_seconds: 90
      )
      raise "confidential client task wrote unexpected console output" unless output.empty?
      raise "confidential client task output was not mode 0600" unless
        File.stat(output_path).mode & 0o777 == 0o600

      values = File.readlines(output_path, chomp: true).to_h do |line|
        key, separator, value = line.partition("=")
        raise "confidential client task output was malformed" if separator.empty? || value.empty?

        [ key, value ]
      end
      raise "confidential client task output fields drifted" unless values.keys.sort == %w[client_id client_secret]

      values
    ensure
      File.unlink(output_path) if output_path && File.file?(output_path)
    end

    def verify_rotations!(app:, rotations:, environment:)
      input_path = File.join(@working_directory, "rotation-check-#{SecureRandom.hex(8)}.json")
      File.open(input_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(rotations))
      end
      runner = <<~RUBY
        require "json"

        checks = JSON.parse(File.read(ENV.fetch("HITCH_ROTATION_CHECKS")))
        checks.each do |check|
          client = Hitch::Client.find_by!(client_id: check.fetch("client_id"))
          abort "old confidential secret remained valid" if client.authenticates_secret?(check.fetch("old_secret"))
          abort "rotated confidential secret was invalid" unless client.authenticates_secret?(check.fetch("new_secret"))
        end
      RUBY
      output = capture!(
        "bundle", "exec", "rails", "runner", runner,
        environment: environment.merge("HITCH_ROTATION_CHECKS" => input_path),
        chdir: app,
        timeout_seconds: 90
      )
      raise "confidential rotation verification wrote unexpected console output" unless output.empty?
    ensure
      File.unlink(input_path) if input_path && File.file?(input_path)
    end

    def with_server(app:, port:, environment:)
      log_path = File.join(@working_directory, "rails-server-#{port}.log")
      log = File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      pid_path = File.join(@working_directory, "rails-server-#{port}.pid")
      pid = Process.spawn(
        environment,
        "bundle", "exec", "rails", "server",
        "--binding", "127.0.0.1", "--port", port.to_s,
        "--environment", "test", "--pid", pid_path,
        chdir: app,
        pgroup: true,
        out: log,
        err: [ :child, :out ]
      )
      log.close
      wait_for_server("http://127.0.0.1:#{port}/.well-known/oauth-authorization-server", pid)
      yield
    ensure
      log&.close unless log&.closed?
      stop_process_group(pid) if pid
    end

    def wait_for_server(url, pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SERVER_READY_SECONDS
      loop do
        waited = Process.waitpid(pid, Process::WNOHANG)
        raise "disposable Rails server exited before readiness" if waited

        begin
          response = Net::HTTP.get_response(URI(url))
          return if response.code == "200"
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError, IOError, SocketError
          nil
        end
        raise "disposable Rails server did not become ready" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
    end

    def stop_process_group(pid)
      Process.kill("TERM", -pid)
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill("KILL", -pid)
      Process.wait(pid)
    end

    def run_client(sdk, config)
      input_path = File.join(@working_directory, "client-#{SecureRandom.hex(8)}.json")
      File.open(input_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(config))
      end
      command = if sdk == "typescript"
        [ "node", runtime.dig("typescript", "executable"), input_path ]
      else
        [ runtime.dig("python", "python"), runtime.dig("python", "executable"), input_path ]
      end
      output = capture_client!(*command)
      marker = output.lines.reverse.find { |line| line.start_with?("HITCH_CLIENT_RESULT=") }
      raise "official #{sdk} client did not report a normalized result" unless marker

      result = JSON.parse(marker.delete_prefix("HITCH_CLIENT_RESULT="))
      raise "official #{sdk} client result named the wrong scenario" unless
        result.fetch("scenario") == config.fetch("scenario")
      raise "official #{sdk} client evidence must not contain credentials" unless
        result.fetch("contains_credentials") == false

      result
    ensure
      File.unlink(input_path) if input_path && File.file?(input_path)
    end

    def capture_client!(*command)
      capture!(*command, chdir: @root, timeout_seconds: CLIENT_TIMEOUT_SECONDS)
    rescue CommandTimedOut
      raise RuntimeError,
        "official client smoke timed out (credential-bearing output withheld)",
        cause: nil
    rescue CommandFailed
      raise RuntimeError,
        "official client smoke failed (credential-bearing output withheld)",
        cause: nil
    end

    def capture!(*command, environment: {}, chdir: @root, timeout_seconds: 60)
      output = +""
      status = nil
      Open3.popen2e(environment, *command, chdir:, pgroup: true) do |stdin, io, wait_thread|
        stdin.close
        reader = Thread.new { io.each { |chunk| output << chunk } }
        begin
          status = Timeout.timeout(timeout_seconds) { wait_thread.value }
        rescue Timeout::Error
          terminate(wait_thread)
          raise CommandTimedOut, "command timed out: #{command.first}"
        ensure
          reader.join
        end
      end
      raise CommandFailed, "command failed: #{command.first}\n#{output}" unless status.success?

      output
    end

    def terminate(wait_thread)
      signal_process_group("TERM", wait_thread.pid)
      begin
        Timeout.timeout(5) { wait_thread.value }
      rescue Timeout::Error
        signal_process_group("KILL", wait_thread.pid)
        wait_thread.value
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    def signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def available_port
      server = TCPServer.new("127.0.0.1", 0)
      server.local_address.ip_port
    ensure
      server&.close
    end

    def verify_checksum!(path, expected, label)
      actual = Digest::SHA256.file(path).hexdigest
      raise "#{label} checksum drifted" unless actual == expected
    end

    private_constant :CommandFailed, :CommandTimedOut
  end
end
