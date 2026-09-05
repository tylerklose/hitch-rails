# frozen_string_literal: true

require "test_helper"
require "timeout"

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

  test "invalid replacement serves no stale snapshot and recovery resolves the new class" do
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
    wait_for(entered)

    reader_started = Queue.new
    reader_result = Queue.new
    reader_thread = Thread.new do
      reader_started << true
      snapshot = @configuration.ensure_registry_prepared!(supported_scopes: [ "mcp" ])
      reader_result << [ :ok, snapshot ]
    rescue StandardError => error
      reader_result << [ :error, error ]
    end
    wait_for(reader_started)
    assert_nil reader_thread.join(0.05), "reader must wait while prepare owns the snapshot lock"

    release << true
    assert prepare_thread.join(5), "registry preparation did not finish"
    assert reader_thread.join(5), "registry reader did not finish"
    prepare_status, prepared = prepare_result.pop
    reader_status, read = reader_result.pop
    assert_equal :ok, prepare_status
    assert_equal :ok, reader_status
    assert_same prepared, read
    assert_equal [ "new descriptor" ], read.entries.map(&:description)
  ensure
    release << true if defined?(release) && release.empty?
    prepare_thread&.join(1)
    reader_thread&.join(1)
  end

  test "concurrent readers reject a failed replacement after retrying validation" do
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
    wait_for(entered)

    reader_started = Queue.new
    reader_result = Queue.new
    reader_thread = Thread.new do
      reader_started << true
      @configuration.ensure_registry_prepared!(supported_scopes: [ "mcp" ])
      reader_result << :unexpected_success
    rescue StandardError => error
      reader_result << error
    end
    wait_for(reader_started)
    assert_nil reader_thread.join(0.05), "reader must not observe stale state during failed prepare"

    release.close
    assert prepare_thread.join(5), "failed registry preparation did not finish"
    assert reader_thread.join(5), "registry reader did not finish"
    prepare_error = prepare_result.pop
    reader_error = reader_result.pop
    assert_instance_of ArgumentError, prepare_error
    assert_instance_of ArgumentError, reader_error
    assert_includes reader_error.message, "description must be a nonblank String"
    assert_equal prepare_error.message, reader_error.message
    assert_raises(ArgumentError) { registry_snapshot }
  ensure
    release&.close
    prepare_thread&.join(1)
    reader_thread&.join(1)
  end

  test "invalidation waits for forced preparation and wins" do
    assert_clear_wins(:prepare_registry!)
  end

  test "invalidation waits for first-use preparation and wins" do
    assert_clear_wins(:ensure_registry_prepared!)
  end

  private

  def assert_clear_wins(preparation)
    entered = Queue.new
    release = Queue.new
    install_blocking_registry(entered:, release:)

    result = Queue.new
    prepare_thread = Thread.new do
      snapshot = @configuration.public_send(preparation, supported_scopes: [ "mcp" ])
      result << [ :ok, snapshot ]
    rescue StandardError => error
      result << [ :error, error ]
    end
    wait_for(entered)

    clear_started = Queue.new
    clear_thread = Thread.new do
      clear_started << true
      @configuration.clear_registry_snapshot!
    end
    wait_for(clear_started)
    assert_nil clear_thread.join(0.05), "invalidation must wait for in-flight registry resolution"

    release << true
    assert prepare_thread.join(5), "registry preparation did not finish"
    assert clear_thread.join(5), "registry invalidation did not finish"
    assert_equal :ok, result.pop.fetch(0)
    assert_raises(ArgumentError) { registry_snapshot }
  ensure
    release << true if defined?(release) && release.empty?
    prepare_thread&.join(1)
    clear_thread&.join(1)
  end

  def install_blocking_registry(entered:, release:)
    namespace = Module.new
    HitchMcpReloadFixtures.const_set(:Blocking, namespace)
    tool = Class.new(Hitch::MCP::Tool)
    namespace.const_set(:Tool, tool)
    configure_tool(tool, description: "blocked descriptor")
    registry = Class.new(Hitch::MCP::Registry)
    registry.register(tool, scopes: [ "mcp" ])
    namespace.define_singleton_method(:const_missing) do |name|
      return super(name) unless name == :Registry

      entered << true
      release.pop
      const_set(:Registry, registry)
    end
    @configuration.registry = "HitchMcpReloadFixtures::Blocking::Registry"
  end

  def wait_for(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def define_reload_pair(tool_name: "reload.tool", description:, description_gate: nil)
    tool = Class.new(Hitch::MCP::Tool)
    HitchMcpReloadFixtures.const_set(:Tool, tool)
    configure_tool(tool, tool_name:, description:)
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
    registry.register(tool, scopes: [ "mcp" ])
    tool
  end

  def configure_tool(tool, tool_name: "reload.tool", description:)
    tool.tool_name tool_name
    tool.description description
    tool.input_schema type: "object", properties: {}, additionalProperties: false
  end

  def prepare_registry
    @configuration.prepare_registry!(supported_scopes: [ "mcp" ])
  end

  def registry_snapshot
    @configuration.registry_snapshot!
  end

  def clear_reload_constants
    HitchMcpReloadFixtures.constants(false).each do |name|
      HitchMcpReloadFixtures.send(:remove_const, name)
    end
  end

  # The snapshot must never retain a reloadable host class. The anonymous SDK
  # wrapper is the exception: it is framework-owned and rebuilt per snapshot.
  def refute_contains_class(value)
    if value.is_a?(Class)
      assert_nil value.name
      assert_operator value, :<, ::MCP::Tool
      refute_operator value, :<, Hitch::MCP::Tool
      return
    end

    children = case value
    when Hash then value.flat_map { |key, child| [ key, child ] }
    when Array then value
    when Data then value.members.map { |member| value.public_send(member) }
    else []
    end
    children.each { |child| refute_contains_class(child) }
  end
end
