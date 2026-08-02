# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class VerifyWorkPacketsTest < ActiveSupport::TestCase
  VERIFIER = Rails.root.join("../../bin/verify-work-packets").expand_path.to_s
  SECTIONS = [
    "Scope",
    "Not in scope",
    "Target files/API",
    "Dependencies",
    "Acceptance commands",
    "Evidence paths",
    "Rollback",
    "Estimate",
    "Risks",
    "Owner"
  ].freeze

  setup do
    @root = Dir.mktmpdir("hitch-work-packets")
    FileUtils.mkdir_p(File.join(@root, "docs/work_packets"))
    write("ROADMAP.md", <<~MARKDOWN)
      # Roadmap fixture

      | Issue | Depends | Target files/API | Acceptance command and evidence | Estimate/risk | Rollback |
      | --- | --- | --- | --- | --- | --- |
      | H0 | — | bootstrap | bootstrap | 1d/low | R1 |
      | M0.1 | H0 | first | first | 1d/low | R1 |
      | M0.2 | M0.1 | second | second | 1d/low | R1 |
    MARKDOWN
    write_index
    write_packet("M0.1", "docs/evidence/0.1.0/first.json")
    write_packet("M0.2", "docs/evidence/0.1.0/second.json")
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts exact graph and writes byte-stable output" do
    first = File.join(@root, "first.json")
    second = File.join(@root, "second.json")

    _stdout, stderr, status = run_verifier("--graph", first)
    assert_predicate status, :success?, stderr
    _stdout, stderr, status = run_verifier("--graph", second)
    assert_predicate status, :success?, stderr
    assert_equal File.binread(first), File.binread(second)
  end

  test "rejects a missing packet node" do
    FileUtils.rm(File.join(@root, "docs/work_packets/M0.2.md"))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "Missing packet nodes: M0.2"
  end

  test "rejects a dependency cycle" do
    write_index(first_dependencies: [ "M0.2" ])

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "Dependency cycle"
  end

  test "rejects an unknown dependency" do
    write_index(second_dependencies: [ "M8" ])

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "unknown predecessor M8"
  end

  test "rejects an unowned command" do
    path = File.join(@root, "docs/work_packets/M0.2.md")
    File.write(path, File.read(path).sub("bin/ci-test", "bin/not-owned"))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "unowned command bin/not-owned"
  end

  test "rejects duplicate evidence ownership" do
    write_packet("M0.2", "docs/evidence/0.1.0/first.json")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "duplicate evidence owners M0.1 and M0.2"
  end

  test "rejects placeholders and missing sections" do
    path = File.join(@root, "docs/work_packets/M0.2.md")
    content = File.read(path).sub("## Risks\n\nBounded risk.\n\n", "")
    File.write(path, content.sub("Complete bounded work.", "TBD"))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "unresolved placeholder"
    assert_includes stderr, "sections must be exactly"
  end

  test "preserves explicit-file validation mode" do
    FileUtils.rm(File.join(@root, "docs/work_packets/M0.2.md"))

    _stdout, stderr, status = run_verifier("M0.1")
    assert_predicate status, :success?, stderr
  end

  test "rejects public distribution before the declared first eligible issue" do
    path = File.join(@root, "docs/work_packets/index.yml")
    content = File.read(path)
    content.sub!(/^(\s*)creates_commands: \[bin\/ci-test, bin\/package-smoke\]$/) do
      indent = ::Regexp.last_match(1)
      [
        "#{indent}creates_commands: [bin/ci-test, bin/package-smoke]",
        "#{indent}artifact:",
        "#{indent}  version: 0.1.0",
        "#{indent}  distribution: public_optional",
        "#{indent}  verifier: bin/package-smoke",
        "#{indent}  public_verifier: bin/release-check"
      ].join("\n")
    end
    File.write(path, content)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "precedes first public-eligible issue M0.1"
  end

  test "rejects a public-eligible artifact without a download verifier" do
    path = File.join(@root, "docs/work_packets/index.yml")
    File.write(path, File.read(path).sub("      public_verifier: bin/release-check\n", ""))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must name a bin/ public_verifier"
  end

  test "accepts a distinct development artifact identity with a contract path" do
    path = File.join(@root, "docs/work_packets/index.yml")
    content = File.read(path).sub(
      "      version: 0.2.0.pre.4\n",
      "      version: 0.2.0.pre.4\n" \
        "      development_version: 0.2.0.pre.4.dev\n" \
        "      contract_path: docs/public_api/0.2.0.md\n"
    )
    File.write(path, content)

    _stdout, stderr, status = run_verifier
    assert_predicate status, :success?, stderr
  end

  test "rejects an ambiguous development artifact identity" do
    path = File.join(@root, "docs/work_packets/index.yml")
    content = File.read(path).sub(
      "      version: 0.2.0.pre.4\n",
      "      version: 0.2.0.pre.4\n" \
        "      development_version: 0.2.0.pre.4\n" \
        "      contract_path: ../wrong.md\n"
    )
    File.write(path, content)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must end in .dev"
    assert_includes stderr, "must differ from its sealed version"
    assert_includes stderr, "must name one docs/public_api markdown file"
  end

  private

  def run_verifier(*arguments)
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root, *arguments)
  end

  def write_index(first_dependencies: [ "H0" ], second_dependencies: [ "M0.1" ])
    write("docs/work_packets/index.yml", <<~YAML)
      schema_version: 2
      distribution_policy:
        first_public_eligible:
          issue: M0.1
          version: 0.2.0.pre.4
          decisions: [published_pre4, deferred_to_final]
        final_public_release:
          issue: M0.2
          version: 0.2.0
      nodes:
        H0:
          depends_on: []
          creates_commands: [bin/ci-test, bin/package-smoke]
        M0.1:
          depends_on: #{first_dependencies.inspect}
          creates_commands: [bin/release-check]
          artifact:
            version: 0.2.0.pre.4
            distribution: public_optional
            verifier: bin/package-smoke
            public_verifier: bin/release-check
        M0.2:
          depends_on: #{second_dependencies.inspect}
          creates_commands: []
          artifact:
            version: 0.2.0
            distribution: public_required
            verifier: bin/package-smoke
            public_verifier: bin/release-check
    YAML
  end

  def write_packet(issue, evidence)
    bodies = SECTIONS.to_h { |section| [ section, section_body(section, evidence) ] }
    content = [ "# Work packet: #{issue}", "" ] + SECTIONS.flat_map do |section|
      [ "## #{section}", "", bodies.fetch(section), "" ]
    end
    write("docs/work_packets/#{issue}.md", content.join("\n"))
  end

  def section_body(section, evidence)
    case section
    when "Acceptance commands"
      "Run:\n\n```sh\nbin/ci-test\n```"
    when "Evidence paths"
      "Create `#{evidence}`."
    when "Scope"
      "Complete bounded work."
    when "Risks"
      "Bounded risk."
    else
      "Complete #{section.downcase}."
    end
  end

  def write(relative_path, content)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
