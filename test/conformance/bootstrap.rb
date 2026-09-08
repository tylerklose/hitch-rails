# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

module Hitch
  module Conformance
    # Why this file is so much machinery for "run the conformance suite".
    #
    # We do not run the official runner. We run a PATCHED build of it, at an
    # alpha version, and we publish the result as evidence that Hitch conforms.
    # Modifying the referee and then citing the referee is only honest if we
    # can prove exactly what we modified. That is what every constant below is
    # for:
    #
    #   COMMIT / SOURCE_SHA256   pin the inputs (npm tags move; a sha cannot)
    #   PATCH_SHA256 / PATCHED_FILES / patch_delta_sha256
    #                            prove the applied delta is exactly the
    #                            reviewed patch, and touches only those files
    #   upstream_test_count: 47  prove the patch did not disable an upstream
    #                            test — the obvious way to cheat a runner you
    #                            are allowed to edit
    #   NODE_VERSION / NPM_VERSION
    #                            NOT a statement about supported Node. They are
    #                            build inputs: the chain above terminates in a
    #                            hash of dist/index.js, and an unpinned compiler
    #                            makes that hash meaningless. Bumping them is
    #                            cheap — change the two constants, the cache
    #                            invalidates, and the manifest records the new
    #                            runner hash.
    #
    # The patch exists because the upstream runner cannot (a) authenticate to a
    # protected server, or (b) authenticate as a confidential client to an
    # authorization server that also advertises `none`. Both are upstream gaps,
    # not Hitch specifics. A third gap, the RFC 8707 resource indicator, was
    # filed as modelcontextprotocol/conformance#465 and merged in #466; the pin
    # now sits on that merge and the resource half of the patch is gone.
    #
    # (a) belongs to their open issue #453 and needs a design we do not own —
    # our local approach only works on the stateless wire (2026-07-28 and
    # draft), so it is deliberately not proposed upstream. (b) is not filed
    # yet; see test/conformance/authorization/harness.rb.
    #
    # This is scaffolding with an expiry date. When #453 is resolved, this file
    # mostly goes away.
    class Bootstrap
      class Failure < StandardError; end

      REPOSITORY = "https://github.com/modelcontextprotocol/conformance.git"
      COMMIT = "a983ba93c91e0bb31d0b6849eeb52f0ad1083107"
      PACKAGE_VERSION = "0.2.0-alpha.11"
      PACKAGE_INTEGRITY = "sha512-imPK9tx5gQsL6ZKQq4MrsyDYfSaIwpRmX6+ogjbeAXs9LGvxkBxWcY7KcS7TvwaBk/ZiVWl6b/naF4q83UwDRA=="
      UPSTREAM_PACKAGE_LOCK_SHA256 = "8c30fe8f15735bc4660c682225b12ec84bbd08c22e839127445d06b5476c4945"
      NODE_VERSION = "v23.7.0"
      NPM_VERSION = "11.1.0"
      PATCH_PATH = "test/conformance/harness.patch"
      PATCH_SHA256 = "e2a144cb620475f1dc24062c40c91140303589579391b53a8ecad2aac163fb78"
      PATCHED_FILES = %w[
        src/connection/index.ts
        src/connection/stateless.test.ts
        src/connection/stateless.ts
        src/scenarios/authorization-server/authorization-code-grant.test.ts
        src/scenarios/authorization-server/authorization-code-grant.ts
        src/scenarios/server/http-standard-headers.ts
      ].freeze
      SOURCE_SHA256 = {
        "package-lock.json" => UPSTREAM_PACKAGE_LOCK_SHA256,
        "package.json" => "f699ac5e56ffeaad1090ee26e126c0d9f9d68e7fad6db30923d30fd7b429c640",
        "src/connection/index.ts" => "87baf5c50c7edd9b5683996e2400d033e68d884ea0639fcb28f351272400d186",
        "src/connection/stateless.test.ts" => "480d12b46b8077b671d6c376415c159ead29930994091d91a2dea11857f5f332",
        "src/connection/stateless.ts" => "73bdcd2bd225ac93d70af02725c7382d1ddbd29f9d077b21cbc89f8fdf50fec4",
        "src/scenarios/authorization-server/authorization-code-grant.test.ts" =>
          "ddb2830c3975fdc976a8d6cebe3386d831e61f4551de73a89c561101244b2180",
        "src/scenarios/authorization-server/authorization-code-grant.ts" =>
          "3b2a59c063b0cb2b61933e1d507ad42cfe16218a8f33445e88fa0e6a147e4b5d",
        "src/scenarios/server/http-standard-headers.ts" =>
          "d3ab710edd60b1f481bdd9cb61f4a855266f0e6a9101a0fd363920fc670716f6"
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
          unless summary.match?(/Test Files\s+4 passed \(4\).*Tests\s+47 passed \(47\)/m)
            raise Failure, "Reviewed harness tests did not execute the exact 47-test set:\n" \
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
            upstream_test_count: 47,
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
