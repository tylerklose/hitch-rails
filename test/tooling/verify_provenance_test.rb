# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class VerifyProvenanceTest < ActiveSupport::TestCase
  VERIFIER = Rails.root.join("../../bin/verify-provenance").expand_path.to_s

  setup do
    @root = Dir.mktmpdir("hitch-provenance")
    FileUtils.mkdir_p(File.join(@root, "docs/architecture"))
    write("docs/architecture/extraction.md", "There are exactly two independent design roots.\nNo third independent root was found.\n")
    write_sources
    write_matrix
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts two roots and a copied descendant" do
    _stdout, stderr, status = run_verifier
    assert_predicate status, :success?, stderr
  end

  test "rejects a copied descendant counted as independent" do
    write_sources(descendant_root: "copy")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "copied descendant changed independence root"
  end

  test "rejects missing full revision pins and absolute paths" do
    write_sources(revision: "main", file: "/private/checkout/server.rb")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "revision must be a full Git SHA"
    assert_includes stderr, "source paths must be relative"
  end

  test "rejects false independent convergence" do
    write_matrix(independent_sources: [ "root_a", "copy" ])

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "independent convergence requires at least two roots"
  end

  test "rejects unknown source and classification" do
    write_matrix(classification: "popular", independent_sources: [ "missing" ])

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "invalid classification"
    assert_includes stderr, "unknown source missing"
  end

  private

  def run_verifier
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root)
  end

  def write_sources(descendant_root: "root_a", revision: "a" * 40, file: "app/server.rb")
    write("docs/architecture/extraction_sources.yml", <<~YAML)
      schema_version: 1
      sources:
        root_a:
          lineage: root
          independence_root: root_a
          parent:
          revision: #{revision}
          files: [#{file.inspect}]
        copy:
          lineage: copied_descendant
          independence_root: #{descendant_root}
          parent: root_a
          revision: #{"b" * 40}
          files: [app/copy.rb]
        root_b:
          lineage: root
          independence_root: root_b
          parent:
          revision: #{"c" * 40}
          files: [app/other.rb]
    YAML
  end

  def write_matrix(classification: "independently_converged", independent_sources: [ "root_a", "root_b" ])
    write("docs/architecture/extraction_matrix.yml", <<~YAML)
      schema_version: 1
      ideas:
        - id: endpoint
          classification: #{classification}
          sources: #{independent_sources.inspect}
          disposition: adopted
          rationale: Repeated behavior.
        - id: copied
          classification: copied_lineage
          sources: [root_a, copy]
          disposition: rejected
          rationale: One lineage only.
    YAML
  end

  def write(relative_path, content)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
