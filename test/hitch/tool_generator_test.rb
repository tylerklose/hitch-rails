# frozen_string_literal: true

require "test_helper"
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
  REGISTRY_PATH = "app/tools/mcp_tool_registry.rb"
  REGISTRY_BYTES = <<~RUBY.freeze
    # frozen_string_literal: true

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

  test "simple generation emits a working tool and registers it" do
    prepare_registry

    output, error = invoke_generator

    assert_predicate self.class.generator_class, :exit_on_failure?
    assert_nil error
    assert_includes output, "Generated and registered Hitch MCP tool McpTools::WeatherLookup"

    tool_path = "app/tools/mcp_tools/weather_lookup.rb"
    test_path = "test/integration/mcp_tools/weather_lookup_test.rb"
    assert_file tool_path, /class WeatherLookup < Hitch::MCP::Tool/
    assert_file tool_path, /tool_name "weather_lookup"/
    assert_file tool_path, /def self\.available_to\?\(_context\)\n      true/
    assert_file tool_path, /Returning without raising ALLOWS the call/
    assert_file tool_path, /^      Result\.text\(/
    refute_match(/^\s*raise\b/, read(tool_path))
    assert_includes read(REGISTRY_PATH), %(  register McpTools::WeatherLookup, scopes: [ "mcp" ]\n)
    # post_mcp calls post, which only integration tests define — a plain
    # ActiveSupport::TestCase would include a helper it cannot use.
    assert_file test_path, /< ActionDispatch::IntegrationTest/
    assert_file test_path, /include Hitch::MCP::TestHelper/
    assert_file test_path, /post_mcp\(method: "tools\/list"/
    assert_file test_path, /method: "tools\/call"/
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(tool_path)) }
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(test_path)) }
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(REGISTRY_PATH)) }
  end

  test "deny-default generation emits the hardened variant and still registers it" do
    prepare_registry

    output, error = invoke_generator(arguments_tail: [ "--deny-default" ])

    assert_nil error
    assert_includes output, "deny-default Hitch MCP tool McpTools::WeatherLookup"
    tool_path = "app/tools/mcp_tools/weather_lookup.rb"
    assert_file tool_path, /def self\.available_to\?\(_context\)\n      false/
    assert_file tool_path, /^      raise Forbidden$/
    assert_file tool_path, /raise "Implement McpTools::WeatherLookup\.perform/
    assert_includes read(REGISTRY_PATH), "register McpTools::WeatherLookup"
    test_path = "test/integration/mcp_tools/weather_lookup_test.rb"
    assert_file test_path, /stays hidden until the host implements and opens it/
    assert_file test_path, /-32602/
  end

  test "pairwise names namespaces registry states and collisions generate completely or write nothing" do
    assert_equal 26, SCENARIOS.length
    assert_equal (1..26).to_a, SCENARIOS.map { |scenario| scenario.fetch("id") }

    SCENARIOS.each do |scenario|
      prepare_destination
      values = scenario.fetch("values")
      prepare_registry if values.fetch("registry") == "present"
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
        assert_includes read(REGISTRY_PATH), identity.fetch(:registration_line), scenario_label(scenario)
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
      prepare_registry
      _output, error = invoke_generator(name_mode:, namespace_mode:)
      identity = identity_for(name_mode, namespace_mode)

      assert_nil error
      assert_includes read(identity.fetch(:tool_path)), "class #{class_name.split('::').last}"
      assert_includes read(identity.fetch(:tool_path)), %(tool_name "#{tool_name}")
      assert_includes read(REGISTRY_PATH), %(register #{class_name}, scopes: [ "mcp" ])
    end
  end

  test "different inputs that normalize to one identity collide without overwrite" do
    prepare_registry
    _output, first_error = invoke_generator(name_mode: "nested_slash")
    before = file_snapshot
    _output, second_error = invoke_generator(name_mode: "nested_constant")

    assert_nil first_error
    assert_instance_of Thor::Error, second_error
    assert_includes second_error.message, "file collision"
    assert_equal before, file_snapshot
  end

  test "rerun and overlong protocol name or namespace refuse before writing" do
    prepare_registry
    _output, first_error = invoke_generator
    before_rerun = file_snapshot
    _output, rerun_error = invoke_generator

    assert_nil first_error
    assert_instance_of Thor::Error, rerun_error
    assert_equal before_rerun, file_snapshot

    prepare_destination
    prepare_registry
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

  test "a missing registry refuses and points at hitch:install" do
    before = file_snapshot

    _output, error = invoke_generator

    assert_instance_of Thor::Error, error
    assert_includes error.message, "run `bin/rails generate hitch:install` first"
    assert_equal before, file_snapshot
  end

  test "destroy removes the generated files and the registration line" do
    prepare_registry
    _output, generation_error = invoke_generator

    _output, rollback_error = invoke_generator(behavior: :revoke)

    identity = identity_for("simple_snake", "default")
    assert_nil generation_error
    assert_nil rollback_error
    assert_no_file identity.fetch(:tool_path)
    assert_no_file identity.fetch(:test_path)
    assert_equal REGISTRY_BYTES, read(REGISTRY_PATH)
  end

  test "destroy refuses a reformatted registration line before deleting anything" do
    prepare_registry
    _output, generation_error = invoke_generator
    reformatted = read(REGISTRY_PATH).sub('[ "mcp" ]', '["mcp"]')
    write(REGISTRY_PATH, reformatted)
    before = file_snapshot

    _output, rollback_error = invoke_generator(behavior: :revoke)

    assert_nil generation_error
    assert_instance_of Thor::Error, rollback_error
    assert_includes rollback_error.message, "edited registration"
    assert_equal before, file_snapshot

    write(REGISTRY_PATH, REGISTRY_BYTES)
    _output, second_rollback_error = invoke_generator(behavior: :revoke)

    identity = identity_for("simple_snake", "default")
    assert_nil second_rollback_error
    assert_no_file identity.fetch(:tool_path)
    assert_no_file identity.fetch(:test_path)
  end

  test "the exact generated tool and test respond through the real endpoint" do
    prepare_registry
    _output, working_error = invoke_generator(raw_name: "generated/weather_lookup")
    _output, hardened_error = invoke_generator(
      raw_name: "generated/locked_tool", arguments_tail: [ "--deny-default" ]
    )
    working = identity_for_raw("generated/weather_lookup", "McpTools")
    hardened = identity_for_raw("generated/locked_tool", "McpTools")
    script = <<~RUBY
      require "test_helper"
      require #{destination_path(working.fetch(:tool_path)).dump}
      require #{destination_path(hardened.fetch(:tool_path)).dump}
      # The registry file carries the injected registrations; loading it
      # reopens the dummy registry exactly the way a host boot would see it.
      load #{destination_path(REGISTRY_PATH).dump}
      principal = User.create!(email: "generated-tool@example.test")
      Hitch.configuration.mcp.prepare_registry!(supported_scopes: Hitch.configuration.supported_scopes)
      Minitest.after_run { principal.reload.destroy }
      load #{destination_path(working.fetch(:test_path)).dump}
      load #{destination_path(hardened.fetch(:test_path)).dump}
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-Itest",
      "-Ilib",
      "-e",
      script,
      chdir: repository_root
    )

    assert_nil working_error
    assert_nil hardened_error
    assert_predicate status, :success?, "#{stdout}\n#{stderr}"
    assert_match(/4 runs, \d+ assertions, 0 failures, 0 errors, 0 skips/, stdout)
  end

  private

  def invoke_generator(name_mode: "simple_snake", namespace_mode: "default",
    raw_name: nil, raw_namespace: nil, arguments_tail: [],
    constant_collision: nil, behavior: :invoke)
    arguments = [ raw_name || NAME_VALUES.fetch(name_mode) ]
    namespace = raw_namespace || NAMESPACE_VALUES.fetch(namespace_mode)
    arguments.concat([ "--namespace", namespace ]) if raw_namespace || namespace_mode != "default"
    arguments.concat(arguments_tail)
    invocation = -> { run_generator(arguments, { behavior:, debug: true }) }
    invocation = constant_collision_wrapper(invocation, constant_collision) if constant_collision
    [ invocation.call, nil ]
  rescue Thor::Error => error
    [ nil, error ]
  end

  def prepare_registry
    write(REGISTRY_PATH, REGISTRY_BYTES)
  end

  def apply_collision(mode, identity)
    return if mode == "none" || mode.end_with?("_constant") || identity.nil?

    path = {
      "tool_file" => identity.fetch(:tool_path),
      "test_file" => identity.fetch(:test_path)
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
      values.fetch("registry") == "present" &&
      values.fetch("collision") == "none"
  end

  def identity_for(name_mode, namespace_mode)
    return if name_mode == "invalid" || namespace_mode == "invalid"

    identity_for_raw(NAME_VALUES.fetch(name_mode), NAMESPACE_VALUES.fetch(namespace_mode))
  end

  def identity_for_raw(raw_name, namespace)
    segments = raw_name.gsub("::", "/").split("/").map do |segment|
      segment.match?(/\A[A-Z]/) ? segment.underscore : segment.tr("-", "_")
    end
    class_name = ([ namespace ] + segments.map(&:camelize)).join("::")
    {
      class_name:,
      test_class_name: "#{class_name}Test",
      tool_name: segments.join("."),
      tool_path: "app/tools/#{class_name.underscore}.rb",
      test_path: "test/integration/#{class_name.underscore}_test.rb",
      registration_line: %(register #{class_name}, scopes: [ "mcp" ])
    }
  end

  def write(relative_path, content)
    path = destination_path(relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def read(relative_path)
    File.binread(destination_path(relative_path))
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
