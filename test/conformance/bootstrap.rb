# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

module Hitch
  module Conformance
    class Bootstrap
      class Failure < StandardError; end

      REPOSITORY = "https://github.com/modelcontextprotocol/conformance.git"
      COMMIT = "a9896553900a2ef61787b57adfcbbe936a8ab1f9"
      PACKAGE_VERSION = "0.2.0-alpha.10"
      PACKAGE_INTEGRITY = "sha512-0V/HZDdWHcg6j0zVBzBsXcPZ571IVi6umKgTpnBhtTx/jm/LONmGF6cIWL2k4Xjyps0OiHV6B37nj2s0pUg0nQ=="
      UPSTREAM_PACKAGE_LOCK_SHA256 = "cc83986778543b99cc7ef22680ed932cab899d068b90ee3d676a7eeab4ae9cf3"
      NODE_VERSION = "v23.7.0"
      NPM_VERSION = "11.1.0"
      PATCH_PATH = "test/conformance/harness.patch"
      PATCH_SHA256 = "495975758b1f42f08c91b46f4151529348d2c8e82e376f672b27d7018faaca8b"
      PATCHED_FILES = %w[
        src/connection/index.ts
        src/connection/stateless.test.ts
        src/connection/stateless.ts
        src/index.ts
        src/scenarios/authorization-server/authorization-code-grant.test.ts
        src/scenarios/authorization-server/authorization-code-grant.ts
        src/scenarios/server/http-standard-headers.ts
        src/schemas.ts
      ].freeze
      SOURCE_SHA256 = {
        "package-lock.json" => UPSTREAM_PACKAGE_LOCK_SHA256,
        "package.json" => "29ef755c66311589bf731763045790aba83adaa462334363c5edad194aa4420b",
        "src/connection/index.ts" => "87baf5c50c7edd9b5683996e2400d033e68d884ea0639fcb28f351272400d186",
        "src/connection/stateless.test.ts" => "dccf811b1090a36e7bc0d1329af332a703b0154536470b6abba3cff87363670d",
        "src/connection/stateless.ts" => "517fb06ec04794632bac5d7dd09da64586089f4e38d1b5c6dadd46a16ae42991",
        "src/index.ts" => "467d34bdb0d5e084b60e1886eb763572e37cb17887e61acc2976d2975513a34c",
        "src/scenarios/authorization-server/authorization-code-grant.test.ts" =>
          "05f4977d39dd0e1f2e6e8a34d609aaf77463e16ea8b1aa9b3129f9f456c092d9",
        "src/scenarios/authorization-server/authorization-code-grant.ts" =>
          "eb533f606e841d1fa710d374419337ca1eb2ba40a1f2f4812cd6a5fda672a0b2",
        "src/scenarios/server/http-standard-headers.ts" =>
          "d3ab710edd60b1f481bdd9cb61f4a855266f0e6a9101a0fd363920fc670716f6",
        "src/schemas.ts" => "7ad0859a285ba3b20a096cd8624c8f9633fa13cad1d371e7c05f025cc79d1a9a"
      }.freeze
      TEST_FILES = %w[
        src/connection/stateless.test.ts
        src/scenarios/server/http-standard-headers.test.ts
        src/scenarios/authorization-server/authorization-server-metadata.test.ts
        src/scenarios/authorization-server/authorization-code-grant.test.ts
      ].freeze

      attr_reader :manifest

      def initialize(root:)
        @root = Pathname(root).expand_path
      end

      def call
        verify_tool_versions!
        verify_local_lock!
        FileUtils.mkdir_p(cache_root)

        File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          return load_cached! if cached?

          build_cache!
        end
      end

      private

      attr_reader :root

      def cache_root
        root.join("tmp/conformance")
      end

      def target
        cache_root.join(COMMIT)
      end

      def lock_path
        cache_root.join("bootstrap.lock")
      end

      def manifest_path(base = target)
        base.join(".hitch-bootstrap.json")
      end

      def patch_path
        root.join(PATCH_PATH)
      end

      def verify_tool_versions!
        node = capture!("node version", {}, "node", "--version").strip
        npm = capture!("npm version", {}, "npm", "--version").strip
        raise Failure, "Expected Node #{NODE_VERSION}, found #{node}" unless node == NODE_VERSION
        raise Failure, "Expected npm #{NPM_VERSION}, found #{npm}" unless npm == NPM_VERSION
      end

      def verify_local_lock!
        package = JSON.parse(root.join("test/conformance/package.json").read)
        lock = JSON.parse(root.join("test/conformance/package-lock.json").read)
        dependency = lock.dig("packages", "node_modules/@modelcontextprotocol/conformance") || {}

        raise Failure, "Local conformance package pin drifted" unless
          package.dig("dependencies", "@modelcontextprotocol/conformance") == PACKAGE_VERSION &&
            lock.dig("packages", "", "dependencies", "@modelcontextprotocol/conformance") == PACKAGE_VERSION &&
            dependency["version"] == PACKAGE_VERSION && dependency["integrity"] == PACKAGE_INTEGRITY
      rescue Errno::ENOENT, JSON::ParserError => error
        raise Failure, "Invalid local conformance package lock: #{error.message}"
      end

      def cached?
        return false unless manifest_path.file? && target.join("dist/index.js").file?

        value = JSON.parse(manifest_path.read)
        value["schema"] == "hitch.conformance-bootstrap.v1" &&
          value.dig("upstream", "commit") == COMMIT &&
          value.dig("extension", "patch_sha256") == PATCH_SHA256 &&
          value.dig("toolchain", "node") == NODE_VERSION &&
          value.dig("toolchain", "npm") == NPM_VERSION &&
          capture!("cached revision", {}, "git", "rev-parse", "HEAD", chdir: target).strip == COMMIT &&
          changed_files(target) == PATCHED_FILES.sort &&
          Digest::SHA256.file(target.join("dist/index.js")).hexdigest == value.dig("verification", "runner_sha256") &&
          patch_delta_sha256(target) == PATCH_SHA256
      rescue JSON::ParserError, Failure
        false
      end

      def load_cached!
        @manifest = JSON.parse(manifest_path.read)
        target
      end

      def build_cache!
        raise Failure, "Harness patch hash mismatch" unless
          patch_path.file? && Digest::SHA256.file(patch_path).hexdigest == PATCH_SHA256

        staging = Pathname(Dir.mktmpdir("bootstrap-", cache_root))
        checkout = staging.join("upstream")
        begin
          run!("clone upstream", {}, "git", "clone", "--filter=blob:none", "--no-checkout", REPOSITORY, checkout.to_s)
          run!("fetch pinned commit", {}, "git", "fetch", "origin", COMMIT, chdir: checkout)
          run!("checkout pinned commit", {}, "git", "checkout", "--detach", COMMIT, chdir: checkout)
          verify_upstream!(checkout)

          run!("install upstream dependencies", {}, "npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", chdir: checkout)
          run!("check reviewed harness patch", {}, "git", "apply", "--check", patch_path.to_s, chdir: checkout)
          run!("apply reviewed harness patch", {}, "git", "apply", patch_path.to_s, chdir: checkout)
          verify_patch!(checkout)
          test_output = capture!(
            "test reviewed harness patch", {}, "npm", "test", "--", *TEST_FILES,
            chdir: checkout
          )
          # vitest colorizes its summary on terminals that advertise color
          # support (GitHub Actions does), so match the uncolored text.
          summary = test_output.gsub(/\e\[[0-9;]*m/, "")
          unless summary.match?(/Test Files\s+4 passed \(4\).*Tests\s+41 passed \(41\)/m)
            raise Failure, "Reviewed harness tests did not execute the exact 41-test set:\n" \
              "#{summary.lines.last(15).join}"
          end
          run!("build reviewed harness", {}, "npm", "run", "build", chdir: checkout)

          File.write(manifest_path(checkout), JSON.pretty_generate(build_manifest(checkout)) << "\n", mode: "w", perm: 0o600)
          # Read the manifest back from the file it just wrote so the fresh
          # path serves exactly what every cached run will read (string keys).
          @manifest = JSON.parse(manifest_path(checkout).read)

          remove_cached_target!
          FileUtils.mv(checkout, target)
          target
        ensure
          FileUtils.remove_entry_secure(staging) if staging&.exist?
        end
      end

      def verify_upstream!(checkout)
        head = capture!("read upstream commit", {}, "git", "rev-parse", "HEAD", chdir: checkout).strip
        raise Failure, "Upstream checkout did not resolve to the pinned commit" unless head == COMMIT

        SOURCE_SHA256.each do |relative, expected|
          actual = Digest::SHA256.file(checkout.join(relative)).hexdigest
          raise Failure, "Pinned upstream source hash mismatch for #{relative}" unless actual == expected
        end
        package = JSON.parse(checkout.join("package.json").read)
        raise Failure, "Pinned upstream package version mismatch" unless package.fetch("version") == PACKAGE_VERSION
      end

      def verify_patch!(checkout)
        changed = changed_files(checkout)
        raise Failure, "Reviewed harness patch touched unexpected files" unless changed == PATCHED_FILES.sort
        raise Failure, "Applied harness delta differs from checked-in patch" unless
          patch_delta_sha256(checkout) == PATCH_SHA256
        run!("check patched source whitespace", {}, "git", "diff", "--check", chdir: checkout)
      end

      def changed_files(checkout)
        capture!("inspect harness delta", {}, "git", "diff", "--name-only", chdir: checkout)
          .lines.map(&:strip).reject(&:empty?).sort
      end

      def patch_delta_sha256(checkout)
        delta = capture!(
          "serialize harness delta", {}, "git", "diff", "--binary", "--", *PATCHED_FILES,
          chdir: checkout
        )
        Digest::SHA256.hexdigest(delta)
      end

      def build_manifest(checkout)
        {
          schema: "hitch.conformance-bootstrap.v1",
          upstream: {
            repository: REPOSITORY.delete_suffix(".git"),
            package: "@modelcontextprotocol/conformance",
            version: PACKAGE_VERSION,
            commit: COMMIT,
            package_lock_sha256: UPSTREAM_PACKAGE_LOCK_SHA256
          },
          toolchain: { node: NODE_VERSION, npm: NPM_VERSION },
          extension: {
            patch: PATCH_PATH,
            patch_sha256: PATCH_SHA256,
            changed_files: PATCHED_FILES,
            upstream_scenario_assertions_changed: false,
            credential_input: "private_file"
          },
          verification: {
            upstream_tests: TEST_FILES,
            upstream_test_count: 41,
            build: "passed",
            runner_sha256: Digest::SHA256.file(checkout.join("dist/index.js")).hexdigest
          }
        }
      end

      def remove_cached_target!
        return unless target.exist?
        raise Failure, "Unsafe conformance cache target" unless
          target.dirname == cache_root && target.basename.to_s == COMMIT

        FileUtils.remove_entry_secure(target)
      end

      def run!(label, environment, *command, chdir: root)
        capture!(label, environment, *command, chdir: chdir)
        true
      end

      def capture!(label, environment, *command, chdir: root)
        stdout, stderr, status = Open3.capture3(environment, *command, chdir: chdir.to_s)
        return stdout if status.success?

        detail = [ stdout, stderr ].join("\n").lines.last(20).join
        raise Failure, "#{label} failed: #{detail.gsub(/\s+/, ' ').strip}"
      rescue Errno::ENOENT => error
        raise Failure, "#{label} failed: #{error.message}"
      end
    end
  end
end
