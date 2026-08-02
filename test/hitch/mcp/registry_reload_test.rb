# frozen_string_literal: true

require "test_helper"

module HitchMcpReloadFixtures
end

class Hitch::MCP::RegistryReloadTest < ActiveSupport::TestCase
  setup do
    clear_reload_constants
    @configuration = Hitch::MCP::Configuration.new
    @configuration.registry = "HitchMcpReloadFixtures::Registry"
  end

  teardown do
    clear_reload_constants
  end

  test "invalid reload serves no stale snapshot and recovery resolves the new class" do
    old_tool = define_reload_pair(description: "old descriptor")
    old_snapshot = prepare_registry
    assert_equal "old descriptor", old_snapshot.entries.fetch(0).description

    clear_reload_constants
    invalid_tool = define_reload_pair(tool_name: "invalid/name", description: "invalid descriptor")
    refute_same old_tool, invalid_tool
    assert_raises(ArgumentError) { prepare_registry }
    assert_raises(ArgumentError) { registry_snapshot }

    clear_reload_constants
    new_tool = define_reload_pair(description: "new descriptor")
    new_snapshot = prepare_registry
    assert_equal "new descriptor", new_snapshot.entries.fetch(0).description
    assert_equal "HitchMcpReloadFixtures::Tool", new_snapshot.entries.fetch(0).class_name
    refute_same old_tool, new_tool
    assert_same new_tool, HitchMcpReloadFixtures.const_get(:Tool, false)
    refute_contains_class new_snapshot
  end

  test "concurrent readers wait for one complete replacement snapshot" do
    define_reload_pair(description: "old descriptor")
    prepare_registry

    clear_reload_constants
    entered = Queue.new
    release = Queue.new
    define_reload_pair(description: "new descriptor", description_gate: [ entered, release ])

    prepare_result = Queue.new
    prepare_thread = Thread.new do
      prepare_result << [ :ok, prepare_registry ]
    rescue StandardError => error
      prepare_result << [ :error, error ]
    end
    entered.pop

    reader_started = Queue.new
    reader_result = Queue.new
    reader_thread = Thread.new do
      reader_started << true
      reader_result << [ :ok, registry_snapshot ]
    rescue StandardError => error
      reader_result << [ :error, error ]
    end
    reader_started.pop
    assert_nil reader_thread.join(0.05), "reader must wait while prepare owns the atomic snapshot lock"

    release << true
    prepare_thread.join
    reader_thread.join
    prepare_status, prepared = prepare_result.pop
    reader_status, read = reader_result.pop
    assert_equal :ok, prepare_status
    assert_equal :ok, reader_status
    assert_same prepared, read
    assert_equal [ "new descriptor" ], read.entries.map(&:description)
  ensure
    release << true if defined?(release) && release.empty?
    prepare_thread&.join
    reader_thread&.join
  end

  test "concurrent readers receive unavailable after a failed replacement" do
    define_reload_pair(description: "old descriptor")
    prepare_registry

    clear_reload_constants
    entered = Queue.new
    release = Queue.new
    define_reload_pair(description: " ", description_gate: [ entered, release ])

    prepare_result = Queue.new
    prepare_thread = Thread.new do
      prepare_registry
      prepare_result << :unexpected_success
    rescue StandardError => error
      prepare_result << error
    end
    entered.pop

    reader_result = Queue.new
    reader_thread = Thread.new do
      registry_snapshot
      reader_result << :unexpected_success
    rescue StandardError => error
      reader_result << error
    end
    assert_nil reader_thread.join(0.05), "reader must not observe the stale snapshot during failed prepare"

    release << true
    prepare_thread.join
    reader_thread.join
    assert_instance_of ArgumentError, prepare_result.pop
    assert_instance_of ArgumentError, reader_result.pop
    assert_raises(ArgumentError) { registry_snapshot }
  ensure
    release << true if defined?(release) && release.empty?
    prepare_thread&.join
    reader_thread&.join
  end

  test "Rails eager load and to_prepare publish the configured dummy registry" do
    original_configuration = Hitch.configuration
    fresh_configuration = Hitch::Configuration.new
    Hitch.instance_variable_set(:@configuration, fresh_configuration)
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = ->(_context) { { name: "dummy", version: "1" } }
    end

    Rails.application.eager_load!
    Rails.application.reloader.prepare!
    snapshot = fresh_configuration.mcp.__send__(:registry_snapshot!)

    assert_equal "McpToolRegistry", snapshot.registry_name
    assert_equal [ "dummy.echo" ], snapshot.entries.map(&:name)
    assert_equal [ "McpTools::Echo" ], snapshot.entries.map(&:class_name)
    refute_contains_class snapshot
  ensure
    Hitch.instance_variable_set(:@configuration, original_configuration) if defined?(original_configuration)
  end

  test "Rails to_prepare fails closed for an invalid configured registry" do
    original_configuration = Hitch.configuration
    fresh_configuration = Hitch::Configuration.new
    Hitch.instance_variable_set(:@configuration, fresh_configuration)
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.mcp.registry = "MissingMcpToolRegistry"
    end

    assert_raises(ArgumentError) { Rails.application.reloader.prepare! }
    assert_raises(ArgumentError) { fresh_configuration.mcp.__send__(:registry_snapshot!) }
  ensure
    Hitch.instance_variable_set(:@configuration, original_configuration) if defined?(original_configuration)
  end

  private

  def define_reload_pair(tool_name: "reload.tool", description:, description_gate: nil)
    tool = Class.new(Hitch::MCP::Tool)
    HitchMcpReloadFixtures.const_set(:Tool, tool)
    tool.tool_name tool_name
    tool.description description
    tool.input_schema type: "object", properties: {}, additionalProperties: false
    if description_gate
      entered, release = description_gate
      tool.define_singleton_method(:description) do
        entered << true
        release.pop
        description
      end
    end

    registry = Class.new(Hitch::MCP::Registry)
    HitchMcpReloadFixtures.const_set(:Registry, registry)
    registry.register tool, scopes: [ "mcp" ]
    tool
  end

  def prepare_registry
    @configuration.__send__(:prepare_registry!, supported_scopes: [ "mcp" ])
  end

  def registry_snapshot
    @configuration.__send__(:registry_snapshot!)
  end

  def clear_reload_constants
    HitchMcpReloadFixtures.constants(false).each do |name|
      HitchMcpReloadFixtures.send(:remove_const, name)
    end
  end

  def refute_contains_class(value)
    refute_kind_of Class, value
    children = case value
    when Hash then value.flat_map { |key, child| [ key, child ] }
    when Array then value
    when Data then value.members.map { |member| value.public_send(member) }
    else []
    end
    children.each { |child| refute_contains_class(child) }
  end
end
