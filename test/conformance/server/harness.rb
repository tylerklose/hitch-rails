# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "socket"
require "timeout"
require "tmpdir"
require "uri"

require_relative "../bootstrap"
require_relative "fixture_tools"
require_relative "result_parser"

module Hitch
  module Conformance
    module Server
      class Harness
        class Failure < StandardError; end

        SPEC_VERSION = "2026-07-28"
        BUNDLE_GEMFILE = "gemfiles/rails_7_2_sqlite.gemfile"

        def initialize(root:)
          @root = Pathname(root).expand_path
          @server_pid = nil
        end

        def run
          verify_retention_configuration!
          bootstrap = Hitch::Conformance::Bootstrap.new(root: root)
          @checkout = bootstrap.call
          @bootstrap_manifest = bootstrap.manifest

          summary = Dir.mktmpdir("hitch-server-conformance-") do |temporary|
            @temporary = Pathname(temporary)
            FileUtils.chmod(0o700, @temporary)
            @raw = @temporary.join("raw")
            @fixtures = @temporary.join("fixtures")
            [ @raw, @fixtures ].each { |directory| FileUtils.mkdir(directory, mode: 0o700) }
            @rails_log_path = @raw.join("rails.log")
            @puma_log_path = @raw.join("puma.log")
            @authorization_file = @fixtures.join("authorization")
            @workspace_log_path = root.join("test/dummy/log/test.log")
            @workspace_log_snapshot = file_snapshot(@workspace_log_path)

            prepare_fixture!
            start_server!
            results = run_scenarios!
            report = ResultParser.call(
              results: results,
              expected_failures_path: root.join("test/conformance/expected-failures.yml")
            )
            stop_server!

            assert_private_files!
            assert_workspace_log_unchanged!
            build_summary(report)
          ensure
            stop_server!
            assert_credentials_absent_from_raw! if @authorization && @raw&.directory?
          end

          assert_summary_redacted!(summary)
          retain_sanitized_evidence!(summary)
          summary
        rescue Hitch::Conformance::Bootstrap::Failure, ResultParser::Failure => error
          raise Failure, error.message
        end

        private

        attr_reader :root

        def verify_retention_configuration!
          return if ENV["HITCH_CONFORMANCE_SERVER_RAW_DIR"].to_s.empty?

          raise Failure,
            "HITCH_CONFORMANCE_SERVER_RAW_DIR is unsupported because raw server runs carry a bearer credential; " \
            "use HITCH_CONFORMANCE_SERVER_EVIDENCE_DIR for a sanitized manifest"
        end

        def prepare_fixture!
          @server_port = available_port
          @resource = "http://127.0.0.1:#{@server_port}/mcp"
          [ @rails_log_path, @puma_log_path ].each { |path| write_private(path, "") }

          environment = rails_environment
          run!(
            "prepare disposable database", environment,
            "bundle", "exec", "rails", "db:prepare",
            chdir: root.join("test/dummy")
          )
          output = capture!(
            "seed authenticated server fixture",
            environment.merge("HITCH_CONFORMANCE_SERVER_AUTHORIZATION_FILE" => @authorization_file.to_s),
            "bundle", "exec", "rails", "runner",
            root.join("test/conformance/server/fixture_setup.rb").to_s,
            chdir: root.join("test/dummy")
          )
          @fixture_manifest = JSON.parse(output.lines.last)
          @authorization = @authorization_file.read
          raise Failure, "Fixture did not produce a bounded bearer credential" unless
            @authorization.match?(/\ABearer [A-Za-z0-9_-]{1,512}\z/)
        rescue JSON::ParserError
          raise Failure, "Server fixture setup did not return its redacted manifest"
        end

        def start_server!
          log = File.open(@puma_log_path, File::WRONLY | File::APPEND, 0o600)
          @server_pid = Process.spawn(
            rails_environment,
            "bundle", "exec", "puma", "-b", "tcp://127.0.0.1:#{@server_port}",
            root.join("test/dummy/config.ru").to_s,
            chdir: root.to_s,
            out: log,
            err: log,
            pgroup: true
          )
          log.close
          wait_for_server!
        end

        def wait_for_server!
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
          uri = URI("http://127.0.0.1:#{@server_port}/.well-known/oauth-protected-resource/mcp")
          loop do
            if (status = Process.waitpid2(@server_pid, Process::WNOHANG)&.last)
              @server_pid = nil
              raise Failure, "Disposable Rails host exited early (#{status.exitstatus}): #{sanitized_server_log}"
            end

            begin
              response = Net::HTTP.get_response(uri)
              return if response.is_a?(Net::HTTPSuccess)
              @last_ready_observation = "HTTP #{response.code}"
            rescue Errno::ECONNREFUSED, Errno::ECONNRESET, EOFError => error
              @last_ready_observation = "#{error.class}: #{error.message}"
            end

            raise Failure,
              "Disposable Rails host did not become ready (#{@last_ready_observation}): #{sanitized_server_log}" if
              Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 0.1
          end
        end

        def run_scenarios!
          ResultParser::SCENARIOS.to_h do |scenario|
            output = @raw.join(scenario)
            FileUtils.mkdir(output, mode: 0o700)
            log_path = @raw.join("#{scenario}.log")
            command = [
              "node", @checkout.join("dist/index.js").to_s, "server",
              "--url", @resource,
              "--scenario", scenario,
              "--spec-version", SPEC_VERSION,
              "--expected-failures", root.join("test/conformance/expected-failures.yml").to_s,
              "--output-dir", output.to_s
            ]
            stdout, stderr, status = Open3.capture3(runner_environment, *command, chdir: @checkout.to_s)
            write_private(log_path, stdout + stderr)
            raise Failure, "Official server scenario #{scenario} failed: #{sanitize(stdout + stderr)}" unless status.success?

            files = Dir.glob(output.join("**/checks.json")).sort
            raise Failure, "Official server scenario #{scenario} emitted #{files.length} checks files" unless files.length == 1

            [ scenario, JSON.parse(File.read(files.first)) ]
          rescue JSON::ParserError
            raise Failure, "Official server scenario #{scenario} emitted malformed checks"
          end
        end

        def build_summary(report)
          {
            schema: "hitch.server-conformance.v1",
            source: {
              commit: capture!("source commit", {}, "git", "rev-parse", "HEAD", chdir: root).strip,
              tree: capture!("source tree", {}, "git", "rev-parse", "HEAD^{tree}", chdir: root).strip,
              worktree_clean_at_run: capture!("source status", {}, "git", "status", "--porcelain=v1", chdir: root).empty?
            },
            upstream: @bootstrap_manifest.fetch("upstream"),
            runner: {
              command: "bin/conformance-server",
              spec_version: SPEC_VERSION,
              node: Hitch::Conformance::Bootstrap::NODE_VERSION,
              npm: Hitch::Conformance::Bootstrap::NPM_VERSION,
              runner_sha256: @bootstrap_manifest.dig("verification", "runner_sha256")
            },
            reviewed_extension: @bootstrap_manifest.fetch("extension"),
            fixture: {
              rails_profile: "Rails 7.2 / SQLite",
              transport: "authenticated localhost HTTP",
              disposable: true,
              fixture_tools: FixtureTools::DEFINITIONS.keys,
              runner_diagnostic_tools: FixtureTools::DIAGNOSTICS.keys,
              production_registry_api_used: false,
              authorization_file_mode: @fixture_manifest.fetch("authorization_file_mode")
            },
            classification: {
              scenarios: "official_upstream_assertions_with_reviewed_transport_input_bridge",
              expected_failures: "hitch_reviewed_check_level_baseline",
              skips: "official_capability_gated_skips",
              exclusions: "explicitly_not_run"
            },
            result: report,
            secret_handling: {
              authorization_value_in_argv: false,
              authorization_value_in_environment: false,
              authorization_file_mode: "0600",
              credential_in_raw_runner_output_or_logs: false,
              credential_in_summary: false,
              ephemeral_database_and_raw_output_deleted: true,
              workspace_log_unchanged: true
            },
            contains_credentials: false,
            raw_artifact: "destroyed after every run and never uploaded; only the sanitized manifest may be retained"
          }
        end

        def rails_environment
          {
            "BUNDLE_GEMFILE" => root.join(BUNDLE_GEMFILE).to_s,
            "DATABASE_URL" => "sqlite3:#{@temporary.join('conformance.sqlite3')}",
            "HITCH_CONFORMANCE" => "1",
            "HITCH_CONFORMANCE_SERVER" => "1",
            "HITCH_CONFORMANCE_RAILS_LOG" => @rails_log_path.to_s,
            "HITCH_CONFORMANCE_RESOURCE_URI" => @resource,
            "RAILS_ENV" => "test"
          }
        end

        def runner_environment
          {
            "MCP_CONFORMANCE_AUTHORIZATION_FILE" => @authorization_file.to_s,
            "NO_COLOR" => "1"
          }
        end

        def assert_private_files!
          [ @authorization_file, @rails_log_path, @puma_log_path ].each do |path|
            raise Failure, "Expected private file #{path.basename} was not created" unless path.file?
            raise Failure, "#{path.basename} is not mode 0600" unless (path.stat.mode & 0o777) == 0o600
          end
        end

        def assert_workspace_log_unchanged!
          return if file_snapshot(@workspace_log_path) == @workspace_log_snapshot

          raise Failure, "Conformance fixture wrote outside its disposable Rails log"
        end

        def assert_credentials_absent_from_raw!
          raw_token = @authorization.delete_prefix("Bearer ")
          leaked = Dir.glob(@raw.join("**/*")).any? do |path|
            File.file?(path) && File.binread(path).include?(raw_token)
          end
          raise Failure, "Bearer credential reached raw conformance output or logs" if leaked
        end

        def assert_summary_redacted!(summary)
          raw_token = @authorization.to_s.delete_prefix("Bearer ")
          raise Failure, "Bearer credential reached sanitized conformance summary" if
            !raw_token.empty? && JSON.generate(summary).include?(raw_token)
        end

        def retain_sanitized_evidence!(summary)
          destination_value = ENV["HITCH_CONFORMANCE_SERVER_EVIDENCE_DIR"]
          return if destination_value.to_s.empty?

          destination = Pathname(destination_value).expand_path
          raise Failure, "Sanitized server evidence destination must not already exist" if destination.exist?

          FileUtils.mkdir_p(destination.parent)
          FileUtils.mkdir(destination, mode: 0o700)
          write_private(destination.join("manifest.json"), JSON.pretty_generate(summary) << "\n")
        end

        def stop_server!
          return unless @server_pid

          Process.kill("TERM", -@server_pid)
          Timeout.timeout(10) { Process.wait(@server_pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        rescue Timeout::Error
          Process.kill("KILL", -@server_pid)
          Process.wait(@server_pid)
        ensure
          @server_pid = nil
        end

        def available_port
          TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
        end

        def sanitized_server_log
          return "no server log" unless @puma_log_path&.file?

          sanitize(@puma_log_path.readlines.last(12).join(" "))
        end

        def sanitize(value)
          redacted = value.to_s
          redacted = redacted.gsub(@authorization.to_s, "[redacted]") unless @authorization.to_s.empty?
          redacted.gsub(/[A-Za-z0-9_~.\/+==-]{40,}/, "[redacted]").gsub(/\s+/, " ").strip
        end

        def file_snapshot(path)
          return { exists: false } unless path.file?

          stat = path.stat
          {
            exists: true,
            device: stat.dev,
            inode: stat.ino,
            bytes: stat.size,
            modified_at: [ stat.mtime.to_i, stat.mtime.nsec ]
          }
        end

        def write_private(path, bytes)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
        end

        def run!(label, environment, *command, chdir: root)
          capture!(label, environment, *command, chdir: chdir)
          true
        end

        def capture!(label, environment, *command, chdir: root)
          stdout, stderr, status = Open3.capture3(environment, *command, chdir: chdir.to_s)
          return stdout if status.success?

          raise Failure, "#{label} failed: #{sanitize(stdout + stderr)}"
        rescue Errno::ENOENT => error
          raise Failure, "#{label} failed: #{error.message}"
        end
      end
    end
  end
end
