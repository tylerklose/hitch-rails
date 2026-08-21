# frozen_string_literal: true

require "test_helper"
require "digest"
require Rails.root.join("../conformance/bootstrap").to_s

class ConformanceBootstrapContractTest < ActiveSupport::TestCase
  test "pins the published package and exact combined harness patch" do
    root = Rails.root.join("../..").expand_path
    package = JSON.parse(root.join("test/conformance/package.json").read)
    lock = JSON.parse(root.join("test/conformance/package-lock.json").read)
    patch_path = root.join(Hitch::Conformance::Bootstrap::PATCH_PATH)

    assert_equal Hitch::Conformance::Bootstrap::PACKAGE_VERSION,
      package.dig("dependencies", "@modelcontextprotocol/conformance")
    assert_equal Hitch::Conformance::Bootstrap::PACKAGE_INTEGRITY,
      lock.dig("packages", "node_modules/@modelcontextprotocol/conformance", "integrity")
    assert_equal Hitch::Conformance::Bootstrap::PATCH_SHA256,
      Digest::SHA256.file(patch_path).hexdigest
  end

  test "patch changes transport inputs but not official scenario verdict assertions" do
    patch = Rails.root.join("../../test/conformance/harness.patch").read
    changed = patch.scan(%r{^diff --git a/(\S+) b/}).flatten

    assert_equal Hitch::Conformance::Bootstrap::PATCHED_FILES, changed
    production_delta = patch.split(/^diff --git /).select do |section|
      section.present? && !section.lines.first.to_s.include?(".test.ts")
    end.join
    refute_match(/^[+-].*(?:checks\.push|status:\s*['\"])/, production_delta)
    assert_includes patch, "MCP_CONFORMANCE_AUTHORIZATION_FILE"
    assert_includes patch, "params.set('resource', options.resource)"
  end
end
