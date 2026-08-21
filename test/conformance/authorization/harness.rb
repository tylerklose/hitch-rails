# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "openssl"
require "pathname"
require "socket"
require "timeout"
require "tmpdir"
require "uri"

module Hitch
  module Conformance
    # The pinning and hash constants below exist for the reason documented at
    # the top of test/conformance/bootstrap.rb: we run a patched build of an
    # alpha third-party runner and publish the result as conformance evidence,
    # so the chain has to prove what was patched.
    #
    # This direction's patch (resource-aware-grants.patch) does two things.
    # The resource indicator half is filed upstream as
    # modelcontextprotocol/conformance#465 / #466 — when that merges, bump the
    # pin and delete that half. The token-endpoint auth-method half is not
    # filed yet: upstream selects `none` whenever an authorization server
    # advertises it, even when a client secret was supplied, so a confidential
    # client cannot be exercised against a server that also supports public
    # clients. That affects any such AS, not just Hitch.
    class AuthorizationHarness
      class Failure < StandardError; end

      REPOSITORY = "https://github.com/modelcontextprotocol/conformance.git"
      COMMIT = "a9896553900a2ef61787b57adfcbbe936a8ab1f9"
      PACKAGE_VERSION = "0.2.0-alpha.10"
      SPEC_VERSION = "2026-07-28"
      NODE_VERSION = "v23.7.0"
      NPM_VERSION = "11.1.0"
      PATCH_SHA256 = "35403574632cf54ca6b133abfa5d52c91499972f17d55904890853ca130d2597"

      # Opt-in: run an unpinned local checkout of the conformance runner instead
      # of the pinned upstream clone plus reviewed patch. For validating an
      # upstream branch that would make the patch unnecessary. Never set in CI —
      # evidence produced this way is stamped unpinned and is not conformance
      # evidence.
      LOCAL_RUNNER_ENV = "HITCH_CONFORMANCE_LOCAL_RUNNER"

      SOURCE_SHA256 = {
        "package-lock.json" => "cc83986778543b99cc7ef22680ed932cab899d068b90ee3d676a7eeab4ae9cf3",
        "package.json" => "29ef755c66311589bf731763045790aba83adaa462334363c5edad194aa4420b",
        "src/index.ts" => "467d34bdb0d5e084b60e1886eb763572e37cb17887e61acc2976d2975513a34c",
        "src/schemas.ts" => "7ad0859a285ba3b20a096cd8624c8f9633fa13cad1d371e7c05f025cc79d1a9a",
        "src/scenarios/authorization-server/authorization-server-metadata.ts" =>
          "3fda4c799ba278295380ba2cf002587da79f95245e4e83b8d3a65e1e349288c8",
        "src/scenarios/authorization-server/authorization-code-grant.ts" =>
          "eb533f606e841d1fa710d374419337ca1eb2ba40a1f2f4812cd6a5fda672a0b2",
        "src/scenarios/authorization-server/authorization-code-grant.test.ts" =>
          "05f4977d39dd0e1f2e6e8a34d609aaf77463e16ea8b1aa9b3129f9f456c092d9"
      }.freeze

      PATCHED_FILES = %w[
        src/index.ts
        src/scenarios/authorization-server/authorization-code-grant.test.ts
        src/scenarios/authorization-server/authorization-code-grant.ts
        src/schemas.ts
      ].freeze

      def initialize(root:, profile:)
        @root = Pathname(root).expand_path
        @profile = profile
        @server_pid = nil
      end

      def run
        verify_tool_versions!
        verify_retention_configuration!

        summary = Dir.mktmpdir("hitch-authorization-conformance-") do |temporary|
          @temporary = Pathname(temporary)
          FileUtils.chmod(0o700, @temporary)
          @checkout = @temporary.join("upstream")
          @raw = @temporary.join("raw")
          @fixtures = @temporary.join("fixtures")
          [ @raw, @fixtures ].each { |directory| FileUtils.mkdir(directory, mode: 0o700) }
          @rails_log_path = @raw.join("rails.log")
          @credential_canary_path = @fixtures.join("credential-canaries.jsonl")
          write_private(@credential_canary_path, "")
          @workspace_log_path = root.join("test/dummy/log/test.log")
          @workspace_log_snapshot = file_snapshot(@workspace_log_path)

          local_runner? ? stage_local_runner! : checkout_upstream!
          install_upstream!
          fixture = prepare_fixture!
          start_server!

          official = run_official_metadata!
          result = base_summary(official)

          if profile == "resource-aware-grants"
            apply_and_test_extension! unless local_runner?
            result[:reviewed_resource_indicator_extension_public] =
              run_extended_grant!("public", @fixtures.join("public-settings.json"), fixture)
            result[:reviewed_resource_indicator_extension_confidential] =
              run_extended_grant!("confidential", @fixtures.join("confidential-settings.json"), fixture)
          end

          stop_server!
          assert_private_rails_log!
          assert_workspace_log_unchanged!
          assert_no_secret_in_summary!(result) if profile == "resource-aware-grants"
          assert_raw_excludes_client_secret! if profile == "resource-aware-grants"
          assert_rails_log_excludes_credentials! if profile == "resource-aware-grants"
          retain_sanitized_evidence!(result)
          result
        ensure
          stop_server!
        end

        summary
      end

      private

      attr_reader :root, :profile

      def base_summary(official)
        {
          schema: "hitch.authorization-conformance.v1",
          profile: profile,
          upstream: {
            repository: REPOSITORY.delete_suffix(".git"),
            package: "@modelcontextprotocol/conformance",
            version: local_runner? ? "unpinned-local-checkout" : PACKAGE_VERSION,
            commit: local_runner? ? "unpinned-local-checkout" : COMMIT,
            package_lock_sha256: SOURCE_SHA256.fetch("package-lock.json"),
            node: NODE_VERSION,
            npm: NPM_VERSION
          },
          fixture: {
            tls: true,
            database: "SQLite",
            rails_app: "disposable",
            credentials_retained: false
          },
          official_unmodified_authorization_metadata: official,
          local_bridge_regression: {
            command: "bin/ci-test test/conformance/authorization",
            acceptance_class: "local_regression_only"
          }
        }
      end

      def verify_tool_versions!
        node = capture!("node version", {}, "node", "--version").strip
        npm = capture!("npm version", {}, "npm", "--version").strip
        raise Failure, "Expected Node #{NODE_VERSION}, found #{node}" unless node == NODE_VERSION
        raise Failure, "Expected npm #{NPM_VERSION}, found #{npm}" unless npm == NPM_VERSION
      end

      def verify_retention_configuration!
        return if ENV["HITCH_CONFORMANCE_RAW_DIR"].to_s.empty?

        raise Failure,
          "HITCH_CONFORMANCE_RAW_DIR is unsupported because upstream raw output contains live credentials; " \
          "use HITCH_CONFORMANCE_EVIDENCE_DIR for sanitized summaries and hashes"
      end

      def local_runner
        @local_runner ||= ENV[LOCAL_RUNNER_ENV].to_s.strip
      end

      def local_runner?
        !local_runner.empty?
      end

      # Copies the working tree — not a git clone — so in-progress edits are
      # what gets exercised. Build inputs only; node_modules and dist are
      # rebuilt by install_upstream!.
      def stage_local_runner!
        source = Pathname(local_runner).expand_path
        raise Failure, "#{LOCAL_RUNNER_ENV} is not a directory: #{source}" unless source.directory?
        raise Failure, "#{LOCAL_RUNNER_ENV} has no package.json: #{source}" unless source.join("package.json").file?

        FileUtils.mkdir_p(@checkout)
        run!(
          "stage local runner", {}, "rsync", "-a",
          "--exclude", ".git", "--exclude", "node_modules", "--exclude", "dist",
          "#{source}/", "#{@checkout}/"
        )
      end

      def checkout_upstream!
        run!("clone upstream", {}, "git", "clone", "--filter=blob:none", "--no-checkout", REPOSITORY, @checkout.to_s)
        run!("fetch pinned commit", {}, "git", "fetch", "origin", COMMIT, chdir: @checkout)
        run!("checkout pinned commit", {}, "git", "checkout", "--detach", COMMIT, chdir: @checkout)

        head = capture!("read upstream commit", {}, "git", "rev-parse", "HEAD", chdir: @checkout).strip
        raise Failure, "Upstream checkout did not resolve to the pinned commit" unless head == COMMIT
        raise Failure, "Pinned upstream checkout is dirty" unless
          capture!("inspect upstream checkout", {}, "git", "status", "--porcelain=v1", chdir: @checkout).empty?

        SOURCE_SHA256.each do |relative, expected|
          actual = Digest::SHA256.file(@checkout.join(relative)).hexdigest
          raise Failure, "Pinned upstream source hash mismatch for #{relative}" unless actual == expected
        end

        package = JSON.parse(@checkout.join("package.json").read)
        raise Failure, "Pinned upstream package version mismatch" unless package.fetch("version") == PACKAGE_VERSION
      end

      def install_upstream!
        run!("install upstream dependencies", {}, "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", chdir: @checkout)
        run!("build pristine upstream", {}, "npm", "run", "build", chdir: @checkout)
      end

      def prepare_fixture!
        @server_port = available_port
        @callback_port = available_port
        @issuer = "https://127.0.0.1:#{@server_port}"
        @resource = "#{@issuer}/mcp"
        create_tls_material!

        environment = rails_environment
        run!("prepare disposable database", environment, "bundle", "exec", "rails", "db:prepare", chdir: root.join("test/dummy"))
        return {} if profile == "metadata"

        fixture_output = capture!(
          "seed conformance fixture",
          environment.merge(
            "HITCH_CONFORMANCE_FIXTURE_DIR" => @fixtures.to_s,
            "HITCH_CONFORMANCE_CALLBACK_PORT" => @callback_port.to_s,
            "HITCH_CONFORMANCE_ISSUER" => @issuer
          ),
          "bundle", "exec", "rails", "runner",
          root.join("test/conformance/authorization/fixture_setup.rb").to_s,
          chdir: root.join("test/dummy")
        )
        JSON.parse(fixture_output.lines.last)
      rescue JSON::ParserError
        raise Failure, "Fixture setup did not return its redacted manifest"
      end

      def create_tls_material!
        ca_key = OpenSSL::PKey::RSA.new(2048)
        ca_certificate = certificate(
          subject: "/CN=Hitch conformance CA",
          key: ca_key,
          issuer_certificate: nil,
          issuer_key: ca_key,
          extensions: [ [ "basicConstraints", "critical,CA:TRUE" ], [ "keyUsage", "critical,keyCertSign,cRLSign" ] ]
        )

        server_key = OpenSSL::PKey::RSA.new(2048)
        server_certificate = certificate(
          subject: "/CN=127.0.0.1",
          key: server_key,
          issuer_certificate: ca_certificate,
          issuer_key: ca_key,
          extensions: [
            [ "basicConstraints", "critical,CA:FALSE" ],
            [ "keyUsage", "critical,digitalSignature,keyEncipherment" ],
            [ "extendedKeyUsage", "serverAuth" ],
            [ "subjectAltName", "IP:127.0.0.1" ]
          ]
        )

        @ca_file = @fixtures.join("ca.pem")
        @key_file = @fixtures.join("server-key.pem")
        @certificate_file = @fixtures.join("server-chain.pem")
        write_private(@ca_file, ca_certificate.to_pem)
        write_private(@key_file, server_key.to_pem)
        write_private(@certificate_file, server_certificate.to_pem + ca_certificate.to_pem)
      end

      def certificate(subject:, key:, issuer_certificate:, issuer_key:, extensions:)
        value = OpenSSL::X509::Certificate.new
        value.version = 2
        value.serial = OpenSSL::BN.rand(128).to_i
        value.subject = OpenSSL::X509::Name.parse(subject)
        value.issuer = issuer_certificate ? issuer_certificate.subject : value.subject
        value.public_key = key.public_key
        value.not_before = Time.now - 60
        value.not_after = Time.now + 3600
        factory = OpenSSL::X509::ExtensionFactory.new
        factory.subject_certificate = value
        factory.issuer_certificate = issuer_certificate || value
        extensions.each { |name, body| value.add_extension(factory.create_extension(name, body)) }
        value.sign(issuer_key, OpenSSL::Digest::SHA256.new)
        value
      end

      def write_private(path, bytes)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
      end

      def start_server!
        @server_log_path = @raw.join("puma.log")
        log = File.open(@server_log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        binding = "ssl://127.0.0.1:#{@server_port}?key=#{@key_file}&cert=#{@certificate_file}"
        @server_pid = Process.spawn(
          rails_environment,
          "bundle", "exec", "puma", "-b", binding, root.join("test/dummy/config.ru").to_s,
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
        loop do
          if (status = Process.waitpid2(@server_pid, Process::WNOHANG)&.last)
            @server_pid = nil
            raise Failure, "Disposable TLS Rails host exited early (#{status.exitstatus}): #{sanitized_server_log}"
          end

          begin
            uri = URI("#{@issuer}/.well-known/oauth-authorization-server")
            response = trusted_http(uri) { |http| http.get(uri.request_uri) }
            return if response.is_a?(Net::HTTPSuccess)
            @last_ready_observation = "HTTP #{response.code}"
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError, EOFError => error
            @last_ready_observation = "#{error.class}: #{error.message}"
          end

          raise Failure,
            "Disposable TLS Rails host did not become ready (#{@last_ready_observation}): #{sanitized_server_log}" if
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.1
        end
      end

      def sanitized_server_log
        return "no server log" unless @server_log_path&.file?

        @server_log_path.readlines.last(12).join(" ")
          .gsub(/[A-Za-z0-9_~.\/+==-]{40,}/, "[redacted]")
          .gsub(/\s+/, " ")
          .strip
      end

      def trusted_http(uri)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        store = OpenSSL::X509::Store.new
        store.set_default_paths
        store.add_file(@ca_file.to_s)
        http.cert_store = store
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.start { yield http }
      end

      def run_official_metadata!
        output = @raw.join("official-metadata")
        FileUtils.mkdir(output, mode: 0o700)
        run!(
          "official authorization metadata scenario",
          node_environment,
          "npm", "run", "start", "--", "authorization",
          "--url", @issuer,
          "--scenario", "authorization-server-metadata-endpoint",
          "--spec-version", SPEC_VERSION,
          "--output-dir", output.to_s,
          chdir: @checkout
        )
        summarize_output!(output, expected_files: 1, expected_checks: 2)
      end

      def apply_and_test_extension!
        patch = root.join("test/conformance/authorization/resource-aware-grants.patch")
        raise Failure, "Reviewed extension patch hash mismatch" unless Digest::SHA256.file(patch).hexdigest == PATCH_SHA256

        run!("check reviewed extension", {}, "git", "apply", "--check", patch.to_s, chdir: @checkout)
        run!("apply reviewed extension", {}, "git", "apply", patch.to_s, chdir: @checkout)

        changed = capture!("inspect extension delta", {}, "git", "diff", "--name-only", chdir: @checkout).lines.map(&:strip)
        raise Failure, "Reviewed extension touched an unexpected source file" unless changed == PATCHED_FILES

        delta = capture!("serialize extension delta", {}, "git", "diff", "--binary", "--", *PATCHED_FILES, chdir: @checkout)
        raise Failure, "Applied extension differs from checked-in patch" unless
          Digest::SHA256.hexdigest(delta) == PATCH_SHA256

        run!(
          "test reviewed extension",
          {},
          "npm", "test", "--",
          "src/scenarios/authorization-server/authorization-server-metadata.test.ts",
          "src/scenarios/authorization-server/authorization-code-grant.test.ts",
          chdir: @checkout
        )
        run!("build reviewed extension", {}, "npm", "run", "build", chdir: @checkout)
      end

      def run_extended_grant!(label, settings, fixture)
        output = @raw.join(label)
        FileUtils.mkdir(output, mode: 0o700)
        log_path = @raw.join("#{label}-runner.log")
        operator_attestation = nil
        command = [
          "npm", "run", "start", "--", "authorization",
          "--file", settings.to_s,
          "--port", @callback_port.to_s,
          "--spec-version", SPEC_VERSION,
          "--output-dir", output.to_s
        ]

        File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |log|
          Open3.popen3(node_environment, *command, chdir: @checkout.to_s) do |stdin, stdout, stderr, wait_thread|
            stdin.close
            error_reader = Thread.new { stderr.each_line { |line| log.write(line) } }
            begin
              stdout.each_line do |line|
                log.write(line)
                next unless line.start_with?("#{@issuer}/oauth/authorize?")

                operator_attestation = run_operator!(line.strip, fixture)
              end
              error_reader.value
              raise Failure, "Extended #{label} runner failed" unless wait_thread.value.success?
            rescue Exception
              Process.kill("TERM", wait_thread.pid) if wait_thread.alive?
              raise
            end
          end
        end

        raise Failure, "Extended #{label} runner never requested browser approval" unless operator_attestation
        {
          extension: {
            base_commit: COMMIT,
            patch_sha256: PATCH_SHA256,
            upstream_conformance_check_assertions_changed: false
          },
          checks: summarize_output!(output, expected_files: 2, expected_checks: 3),
          operator: operator_attestation
        }
      end

      def run_operator!(authorization_url, fixture)
        stdout = capture!(
          "browser operator",
          rails_environment,
          "bundle", "exec", "ruby",
          root.join("test/conformance/authorization/browser_operator.rb").to_s,
          "--issuer", @issuer,
          "--user-id", fixture.fetch("user_id").to_s,
          "--resource", @resource,
          "--redirect-uri", fixture.fetch("callback_uri"),
          "--ca-file", @ca_file.to_s,
          chdir: root,
          stdin_data: "#{authorization_url}\n"
        )
        JSON.parse(stdout)
      rescue JSON::ParserError
        raise Failure, "Browser operator did not return a redacted attestation"
      end

      def summarize_output!(directory, expected_files:, expected_checks:)
        files = Dir.glob(directory.join("**/checks.json")).sort
        raise Failure, "Runner emitted an unexpected checks.json file count" unless files.length == expected_files

        checks = files.flat_map { |path| JSON.parse(File.read(path)) }
        raise Failure, "Runner emitted an unexpected check count" unless checks.length == expected_checks

        rejected = checks.reject { |check| check.fetch("status") == "SUCCESS" }
        raise Failure, "Runner emitted failure, skip, or warning statuses" if rejected.any?

        checks.map do |check|
          check.slice("id", "name", "description", "status", "specReferences")
        end
      end

      def assert_no_secret_in_summary!(summary)
        settings = JSON.parse(@fixtures.join("confidential-settings.json").read)
        secret = settings.fetch("clientSecret")
        serialized = JSON.generate(summary)
        raise Failure, "Confidential fixture secret reached sanitized output" if serialized.include?(secret)
      end

      def assert_raw_excludes_client_secret!
        settings = JSON.parse(@fixtures.join("confidential-settings.json").read)
        secret = settings.fetch("clientSecret")
        leaked = Dir.glob(@raw.join("**/*")).any? do |path|
          File.file?(path) && File.binread(path).include?(secret)
        end
        raise Failure, "Confidential fixture secret reached raw runner artifacts" if leaked
      end

      def assert_private_rails_log!
        raise Failure, "Disposable Rails log was not created" unless @rails_log_path.file?
        raise Failure, "Disposable Rails log is not mode 0600" unless (@rails_log_path.stat.mode & 0o777) == 0o600
      end

      def assert_workspace_log_unchanged!
        return if file_snapshot(@workspace_log_path) == @workspace_log_snapshot

        raise Failure, "Conformance fixture wrote outside its disposable Rails log"
      end

      def assert_rails_log_excludes_credentials!
        settings = JSON.parse(@fixtures.join("confidential-settings.json").read)
        entries = @credential_canary_path.readlines(chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
        raise Failure, "Expected two successful token credential canary records" unless entries.length == 2

        canaries = [ settings.fetch("clientSecret") ] + entries.flat_map do |entry|
          entry.values_at("authorization_code", "code_verifier", "access_token")
        end
        raise Failure, "Credential canary capture was incomplete" if canaries.any? { |value| value.to_s.empty? }

        log = @rails_log_path.binread
        raise Failure, "A credential canary reached the disposable Rails log" if canaries.any? { |value| log.include?(value) }
      rescue JSON::ParserError
        raise Failure, "Credential canary fixture was malformed"
      end

      def retain_sanitized_evidence!(summary)
        destination_value = ENV["HITCH_CONFORMANCE_EVIDENCE_DIR"]
        return if destination_value.to_s.empty?

        destination = Pathname(destination_value).expand_path
        raise Failure, "Sanitized evidence destination must not already exist" if destination.exist?

        FileUtils.mkdir_p(destination.parent)
        FileUtils.mkdir(destination, mode: 0o700)
        files = Dir.glob(@raw.join("**/*")).select { |path| File.file?(path) }.sort.map do |path|
          pathname = Pathname(path)
          {
            path: pathname.relative_path_from(@raw).to_s,
            bytes: pathname.size,
            sha256: Digest::SHA256.file(pathname).hexdigest
          }
        end
        manifest = {
          schema: "hitch.authorization-conformance-evidence.v1",
          profile: profile,
          contains_credentials: false,
          summary: summary,
          ephemeral_raw_file_hashes: files
        }
        write_private(destination.join("manifest.json"), JSON.pretty_generate(manifest) << "\n")
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

      def rails_environment
        {
          "BUNDLE_GEMFILE" => root.join("gemfiles/rails_8_0_sqlite.gemfile").to_s,
          "DATABASE_URL" => "sqlite3:#{@temporary.join('conformance.sqlite3')}",
          "HITCH_CONFORMANCE" => "1",
          "HITCH_CONFORMANCE_CANARY_FILE" => @credential_canary_path.to_s,
          "HITCH_CONFORMANCE_ISSUER" => @issuer,
          "HITCH_CONFORMANCE_RAILS_LOG" => @rails_log_path.to_s,
          "HITCH_CONFORMANCE_RESOURCE_URI" => @resource,
          "RAILS_ENV" => "test"
        }
      end

      def node_environment
        { "NODE_EXTRA_CA_CERTS" => @ca_file.to_s }
      end

      def available_port
        TCPServer.open("127.0.0.1", 0) { |server| server.addr[1] }
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

      def run!(label, environment, *command, chdir: nil)
        capture!(label, environment, *command, chdir: chdir)
        true
      end

      def capture!(label, environment, *command, chdir: nil, stdin_data: "")
        stdout, _stderr, status = Open3.capture3(
          environment,
          *command,
          chdir: (chdir || root).to_s,
          stdin_data: stdin_data
        )
        raise Failure, "#{label} failed" unless status.success?

        stdout
      end
    end
  end
end
