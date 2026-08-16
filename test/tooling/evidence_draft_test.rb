# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../../tooling/evidence_draft"

class EvidenceDraftTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("hitch-evidence-draft-")
  end

  teardown do
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  test "all future evidence templates have their complete checked shape" do
    HitchEvidenceDraft::KINDS.each do |kind, (filename, _schema, _milestone)|
      result = HitchEvidenceDraft.validate!(
        kind:,
        path: Rails.root.join("../..", HitchEvidenceDraft::TEMPLATE_ROOT, filename).expand_path.to_s
      )

      assert_equal kind, result.fetch("kind")
      assert_operator result.fetch("placeholders"), :>, 0
    end
  end

  test "ready mode rejects every unreplaced placeholder" do
    path = template_copy("product_clients")

    error = assert_raises(HitchEvidenceDraft::VerificationError) do
      HitchEvidenceDraft.validate!(kind: "product_clients", path:, ready: true)
    end

    assert_includes error.message, "unreplaced placeholders"
    assert_includes error.message, "product_clients.status"
  end

  test "rejects missing nested fields and duplicate JSON members" do
    path = template_copy("publication_authority")
    document = JSON.parse(File.read(path))
    document.fetch("candidate").delete("source_tree")
    File.write(path, JSON.pretty_generate(document))

    error = assert_raises(HitchEvidenceDraft::VerificationError) do
      HitchEvidenceDraft.validate!(kind: "publication_authority", path:)
    end
    assert_includes error.message, "publication_authority.candidate fields must be exactly"

    duplicate = template_copy("downloaded_gem")
    File.write(duplicate, '{"schema":"one","schema":"two"}')
    error = assert_raises(HitchEvidenceDraft::VerificationError) do
      HitchEvidenceDraft.validate!(kind: "downloaded_gem", path: duplicate)
    end
    assert_includes error.message, "duplicate key"
  end

  test "fixed evidence arrays cannot pass with illustrative or empty cardinality" do
    product_path = template_copy("product_clients")
    product = JSON.parse(File.read(product_path))
    product["clients"] = []
    File.write(product_path, JSON.pretty_generate(product))

    error = assert_raises(HitchEvidenceDraft::VerificationError) do
      HitchEvidenceDraft.validate!(kind: "product_clients", path: product_path)
    end
    assert_includes error.message, "product_clients.clients must contain exactly 2 items"

    copied_path = template_copy("copied_lineage")
    copied = JSON.parse(File.read(copied_path))
    copied.dig("benchmark")["operations"] = []
    File.write(copied_path, JSON.pretty_generate(copied))

    error = assert_raises(HitchEvidenceDraft::VerificationError) do
      HitchEvidenceDraft.validate!(kind: "copied_lineage", path: copied_path, ready: true)
    end
    assert_includes error.message, "must contain exactly tools/list and tools/call"
  end

  test "nullable rerun placeholders retain their typed ready-mode boundary" do
    assert_empty placeholder_errors("nullable-command", nil)
    assert_empty placeholder_errors("nullable-commit", "a" * 40)
    assert_empty placeholder_errors("nullable-sha256", "b" * 64)
    assert_empty placeholder_errors("nullable-timestamp", "2026-08-03T12:00:00Z")

    assert_includes placeholder_errors("nullable-commit", "not-a-commit").first, "nullable-commit"
    assert_includes placeholder_errors("nullable-timestamp", "sometime").first, "ISO-8601"
  end

  private

  def template_copy(kind)
    filename = HitchEvidenceDraft::KINDS.fetch(kind).fetch(0)
    source = Rails.root.join("../..", HitchEvidenceDraft::TEMPLATE_ROOT, filename).expand_path
    destination = File.join(@directory, filename)
    FileUtils.cp(source, destination)
    destination
  end

  def placeholder_errors(type, value)
    HitchEvidenceDraft.__send__(:placeholder_errors, type, value, "rerun.field", ready: true)
  end
end
