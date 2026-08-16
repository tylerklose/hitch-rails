# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rails/generators/test_case"
require "generators/hitch/tool_generator"

class Hitch::ToolGeneratorTest < Rails::Generators::TestCase
  tests Hitch::Generators::ToolGenerator
  destination File.expand_path("../../tmp/tool_generator", __dir__)
  setup :prepare_destination

  SCENARIO_PATH = Rails.root.join("../lattice/tool_generator_scenarios.json").expand_path
  SCENARIOS = JSON.parse(SCENARIO_PATH.read).fetch("scenarios").freeze
  REGISTRY_PATH = "app/models/mcp_tool_registry.rb"
  REGISTRY_BYTES = <<~RUBY.freeze
    # host-owned registry sentinel
    class McpToolRegistry < Hitch::MCP::Registry
    end
  RUBY
  NAME_VALUES = {
    "simple_snake" => "weather_lookup",
    "nested_slash" => "billing/customer_lookup",
    "nested_constant" => "Billing::CustomerLookup",
    "hyphenated" => "account-summary",
    "invalid" => "bad name!"
  }.freeze
  NAMESPACE_VALUES = {
    "default" => "McpTools",
    "custom_valid" => "Admin::McpTools",
    "invalid" => "admin/tools"
  }.freeze

  test "simple generation is deny-default and reports one manual registration line" do
    prepare_registry("present")

    output, error = invoke_generator

    assert_predicate self.class.generator_class, :exit_on_failure?
    assert_nil error
    assert_includes output, "Generated deny-default Hitch MCP tool McpTools::WeatherLookup"
    assert_includes output, 'register McpTools::WeatherLookup, scopes: [ "mcp" ]'
    assert_equal REGISTRY_BYTES, read(REGISTRY_PATH)

    tool_path = "app/models/mcp_tools/weather_lookup.rb"
    test_path = "test/integration/mcp_tools/weather_lookup_test.rb"
    assert_file tool_path, /class WeatherLookup < Hitch::MCP::Tool/
    assert_file tool_path, /tool_name "weather_lookup"/
    assert_file tool_path, /def self\.available_to\?\(_context\)\n      false/
    assert_file tool_path, /raise Hitch::MCP::Forbidden/
    assert_file tool_path, /additionalProperties: false/
    # post_mcp calls post, which only integration tests define — a plain
    # ActiveSupport::TestCase would include a helper it cannot use.
    assert_file test_path, /< ActionDispatch::IntegrationTest/
    assert_file test_path, /include Hitch::MCP::TestHelper/
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(tool_path)) }
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(test_path)) }
    assert_manifest(identity_for("simple_snake", "default"))
  end

  test "pairwise names namespaces registry states and collisions install completely or write nothing" do
    assert_equal 31, SCENARIOS.length
    assert_equal (1..31).to_a, SCENARIOS.map { |scenario| scenario.fetch("id") }

    SCENARIOS.each do |scenario|
      prepare_destination
      values = scenario.fetch("values")
      prepare_registry(values.fetch("registry"))
      identity = identity_for(values.fetch("name"), values.fetch("namespace"))
      apply_collision(values.fetch("collision"), identity)
      before = file_snapshot

      _output, error = invoke_generator(
        name_mode: values.fetch("name"),
        namespace_mode: values.fetch("namespace"),
        constant_collision: constant_collision_target(values.fetch("collision"), identity)
      )

      if successful_scenario?(values)
        assert_nil error, scenario_label(scenario)
        assert destination_file?(identity.fetch(:tool_path)), scenario_label(scenario)
        assert destination_file?(identity.fetch(:test_path)), scenario_label(scenario)
        assert destination_file?(identity.fetch(:manifest_path)), scenario_label(scenario)
        assert_registry_unchanged(values.fetch("registry"), scenario_label(scenario))
      else
        assert_instance_of Thor::Error, error, scenario_label(scenario)
        assert_equal before, file_snapshot, scenario_label(scenario)
      end
    end
  end

  test "slash constant and hyphen forms normalize to deterministic class and MCP names" do
    expectations = {
      [ "nested_slash", "default" ] => [
        "McpTools::Billing::CustomerLookup",
        "billing.customer_lookup"
      ],
      [ "nested_constant", "custom_valid" ] => [
        "Admin::McpTools::Billing::CustomerLookup",
        "billing.customer_lookup"
      ],
      [ "hyphenated", "default" ] => [
        "McpTools::AccountSummary",
        "account_summary"
      ]
    }

    expectations.each do |(name_mode, namespace_mode), (class_name, tool_name)|
      prepare_destination
      _output, error = invoke_generator(name_mode:, namespace_mode:)
      identity = identity_for(name_mode, namespace_mode)

      assert_nil error
      assert_includes read(identity.fetch(:tool_path)), "class #{class_name.split('::').last}"
      assert_includes read(identity.fetch(:tool_path)), %(tool_name "#{tool_name}")
      assert_manifest(identity)
    end
  end

  test "different inputs that normalize to one identity collide without overwrite" do
    _output, first_error = invoke_generator(name_mode: "nested_slash")
    before = file_snapshot
    _output, second_error = invoke_generator(name_mode: "nested_constant")

    assert_nil first_error
    assert_instance_of Thor::Error, second_error
    assert_includes second_error.message, "file collision"
    assert_equal before, file_snapshot
  end

  test "rerun and overlong protocol name or namespace refuse before writing" do
    _output, first_error = invoke_generator
    before_rerun = file_snapshot
    _output, rerun_error = invoke_generator

    assert_nil first_error
    assert_instance_of Thor::Error, rerun_error
    assert_equal before_rerun, file_snapshot

    prepare_destination
    before_long_name = file_snapshot
    _output, long_name_error = invoke_generator(raw_name: "a" * 65)

    assert_instance_of Thor::Error, long_name_error
    assert_includes long_name_error.message, "1 to 64 characters"
    assert_equal before_long_name, file_snapshot

    _output, long_namespace_error = invoke_generator(
      raw_name: "valid",
      raw_namespace: "#{'A' * 65}::Tools"
    )

    assert_instance_of Thor::Error, long_namespace_error
    assert_includes long_namespace_error.message, "bounded constant path"
    assert_equal before_long_name, file_snapshot
  end

  test "exact rollback removes generated bytes while preserving the registry" do
    prepare_registry("present")
    _output, generation_error = invoke_generator

    _output, rollback_error = invoke_generator(behavior: :revoke)

    identity = identity_for("simple_snake", "default")
    assert_nil generation_error
    assert_nil rollback_error
    assert_no_file identity.fetch(:tool_path)
    assert_no_file identity.fetch(:test_path)
    assert_no_file identity.fetch(:manifest_path)
    assert_equal REGISTRY_BYTES, read(REGISTRY_PATH)
  end

  test "rollback refuses while the exact manual registry instruction remains" do
    prepare_registry("present")
    _output, generation_error = invoke_generator
    append(REGISTRY_PATH, "  register McpTools::WeatherLookup, scopes: [ \"mcp\" ]\n")
    before = file_snapshot

    _output, first_rollback_error = invoke_generator(behavior: :revoke)

    assert_nil generation_error
    assert_instance_of Thor::Error, first_rollback_error
    assert_includes first_rollback_error.message, "still contains the manual registration line"
    assert_equal before, file_snapshot

    write(REGISTRY_PATH, REGISTRY_BYTES)
    _output, second_rollback_error = invoke_generator(behavior: :revoke)

    assert_nil second_rollback_error
    assert_equal REGISTRY_BYTES, read(REGISTRY_PATH)
  end

  test "rollback refuses customized files and inconsistent manifests without partial deletion" do
    customizations = {
      "tool" => ->(_identity) { append("app/models/mcp_tools/weather_lookup.rb", "# host edit\n") },
      "test" => ->(_identity) { append("test/integration/mcp_tools/weather_lookup_test.rb", "# host edit\n") }
    }
    manifest_tamperings = {
      "canonical name" => ->(manifest) { manifest["canonical_name"] = "anything" },
      "class" => ->(manifest) { manifest["class_name"] = "McpTools::Anything" },
      "tool path" => ->(manifest) { manifest.fetch("files").first["path"] = REGISTRY_PATH },
      "registration" => ->(manifest) { manifest["registry_instruction"] = "register Anything" },
      "rollback command" => ->(manifest) { manifest["rollback_command"] = "bin/rails destroy anything" }
    }

    customizations.each do |label, customize|
      assert_refused_rollback(label) { |identity, _manifest| customize.call(identity) }
    end
    manifest_tamperings.each do |label, tamper|
      assert_refused_rollback(label) { |_identity, manifest| tamper.call(manifest) }
    end
  end

  test "the exact generated Minitest file runs successfully" do
    _output, error = invoke_generator(raw_name: "generated/weather_lookup")
    identity = identity_for_raw("generated/weather_lookup", "McpTools")
    script = <<~RUBY
      require "test_helper"
      require #{destination_path(identity.fetch(:tool_path)).dump}
      load #{destination_path(identity.fetch(:test_path)).dump}
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-Itest",
      "-Ilib",
      "-e",
      script,
      chdir: repository_root
    )

    assert_nil error
    assert_predicate status, :success?, "#{stdout}\n#{stderr}"
    assert_match(/3 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, stdout)
  end

  private

  def invoke_generator(name_mode: "simple_snake", namespace_mode: "default",
    raw_name: nil, raw_namespace: nil, constant_collision: nil, behavior: :invoke)
    arguments = [ raw_name || NAME_VALUES.fetch(name_mode) ]
    namespace = raw_namespace || NAMESPACE_VALUES.fetch(namespace_mode)
    arguments.concat([ "--namespace", namespace ]) if raw_namespace || namespace_mode != "default"
    invocation = -> { run_generator(arguments, { behavior:, debug: true }) }
    invocation = constant_collision_wrapper(invocation, constant_collision) if constant_collision
    [ invocation.call, nil ]
  rescue Thor::Error => error
    [ nil, error ]
  end

  def prepare_registry(mode)
    return if mode == "absent"

    write(REGISTRY_PATH, REGISTRY_BYTES)
  end

  def assert_registry_unchanged(mode, label)
    if mode == "present"
      assert_equal REGISTRY_BYTES, read(REGISTRY_PATH), label
    else
      refute destination_file?(REGISTRY_PATH), label
    end
  end

  def apply_collision(mode, identity)
    return if mode == "none" || mode.end_with?("_constant") || identity.nil?

    path = {
      "tool_file" => identity.fetch(:tool_path),
      "test_file" => identity.fetch(:test_path),
      "manifest" => identity.fetch(:manifest_path)
    }.fetch(mode)
    write(path, "host-owned collision\n")
  end

  def constant_collision_target(mode, identity)
    return unless identity
    return identity.fetch(:class_name) if mode == "tool_constant"

    identity.fetch(:test_class_name) if mode == "test_constant"
  end

  def constant_collision_wrapper(invocation, target)
    original_defined = Object.method(:const_defined?)
    original_source = Object.method(:const_source_location)
    fake_source = destination_path("config/collision.rb")
    defined = lambda do |name, inherit = true|
      name.to_s == target ? true : original_defined.call(name, inherit)
    end
    source = lambda do |name, inherit = true|
      name.to_s == target ? [ fake_source, 1 ] : original_source.call(name, inherit)
    end

    -> do
      stub_class_method(Object, :const_defined?, defined) do
        stub_class_method(Object, :const_source_location, source) { invocation.call }
      end
    end
  end

  def successful_scenario?(values)
    values.fetch("name") != "invalid" &&
      values.fetch("namespace") != "invalid" &&
      values.fetch("collision") == "none"
  end

  def identity_for(name_mode, namespace_mode)
    return if name_mode == "invalid" || namespace_mode == "invalid"

    identity_for_raw(NAME_VALUES.fetch(name_mode), NAMESPACE_VALUES.fetch(namespace_mode))
  end

  def identity_for_raw(raw_name, namespace)
    segments = raw_name.gsub("::", "/").split("/").map do |segment|
      candidate = segment.match?(/\A[A-Z]/) ? segment.underscore : segment.tr("-", "_")
      candidate
    end
    canonical_name = segments.join("/")
    tool_name = segments.join(".")
    class_name = ([ namespace ] + segments.map(&:camelize)).join("::")
    {
      canonical_name:,
      namespace:,
      class_name:,
      test_class_name: "#{class_name}Test",
      tool_name:,
      tool_path: "app/models/#{class_name.underscore}.rb",
      test_path: "test/integration/#{class_name.underscore}_test.rb",
      manifest_path: "config/hitch_tools/#{tool_name}.json",
      registration_line: %(register #{class_name}, scopes: [ "mcp" ]),
      rollback_command: [
        "bin/rails destroy hitch:tool",
        canonical_name,
        ("--namespace #{namespace}" unless namespace == "McpTools")
      ].compact.join(" ")
    }
  end

  def assert_manifest(identity)
    manifest = JSON.parse(read(identity.fetch(:manifest_path)))
    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "hitch:tool", manifest.fetch("generator")
    assert_equal identity.fetch(:canonical_name), manifest.fetch("canonical_name")
    assert_equal identity.fetch(:namespace), manifest.fetch("namespace")
    assert_equal identity.fetch(:class_name), manifest.fetch("class_name")
    assert_equal identity.fetch(:tool_name), manifest.fetch("tool_name")
    assert_equal identity.fetch(:registration_line), manifest.fetch("registry_instruction")
    assert_equal identity.fetch(:rollback_command), manifest.fetch("rollback_command")
    assert_equal [ identity.fetch(:tool_path), identity.fetch(:test_path) ],
      manifest.fetch("files").map { |file| file.fetch("path") }
    manifest.fetch("files").each do |file|
      assert_equal Digest::SHA256.file(destination_path(file.fetch("path"))).hexdigest,
        file.fetch("sha256")
    end
  end

  def assert_refused_rollback(label)
    prepare_destination
    prepare_registry("present")
    _output, generation_error = invoke_generator
    identity = identity_for("simple_snake", "default")
    manifest_path = destination_path(identity.fetch(:manifest_path))
    manifest = JSON.parse(File.binread(manifest_path))
    yield identity, manifest
    File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
    before = file_snapshot

    _output, rollback_error = invoke_generator(behavior: :revoke)

    assert_nil generation_error, label
    assert_instance_of Thor::Error, rollback_error, label
    assert_includes rollback_error.message, "rollback refused", label
    assert_equal before, file_snapshot, label
  end

  def write(relative_path, content)
    path = destination_path(relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def read(relative_path)
    File.binread(destination_path(relative_path))
  end

  def append(relative_path, content)
    File.open(destination_path(relative_path), "ab") { |file| file.write(content) }
  end

  def destination_file?(relative_path)
    File.file?(destination_path(relative_path))
  end

  def destination_path(relative_path)
    File.expand_path(relative_path, destination_root)
  end

  def file_snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: destination_root).sort.filter_map do |relative_path|
      absolute_path = destination_path(relative_path)
      [ relative_path, File.binread(absolute_path) ] if File.file?(absolute_path)
    end.to_h
  end

  def repository_root
    Rails.root.join("../..").expand_path.to_s
  end

  def scenario_label(scenario)
    "scenario #{scenario.fetch('id')}: #{scenario.fetch('values')}"
  end
end
