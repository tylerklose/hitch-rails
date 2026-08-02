# frozen_string_literal: true

require "test_helper"

module HitchMcpRegistryFixtures
end

class Hitch::MCP::RegistryTest < ActiveSupport::TestCase
  NOT_SET = Object.new.freeze
  VALID_INPUT_SCHEMA = {
    type: "object",
    properties: { message: { type: "string" } },
    required: [ "message" ],
    additionalProperties: false
  }.freeze

  setup do
    clear_fixtures
    @configuration = Hitch::MCP::Configuration.new
    @sequence = 0
  end

  teardown do
    clear_fixtures
  end

  test "valid declarations become one deterministic class-name-only snapshot" do
    mutable_name = +"zeta.tool"
    mutable_description = +"Zeta description"
    mutable_property = +"message"
    mutable_scope = +"mcp"
    zeta = define_tool(
      tool_name: mutable_name,
      description: mutable_description,
      input_schema: {
        type: "object",
        properties: { mutable_property => { type: :string } }
      },
      output_schema: { type: "object", properties: { echoed: { type: "string" } } },
      annotations: { "readOnlyHint" => true, open_world_hint: false }
    )
    alpha = define_tool(tool_name: "alpha.tool", description: "Alpha description")
    registry = define_registry([ zeta, [ mutable_scope ] ], [ alpha, [ "mcp" ] ])

    mutable_registry_name = +registry.name
    @configuration.registry = mutable_registry_name
    mutable_registry_name.replace("AttackerRegistry")
    mutable_name.replace("attacker.tool")
    mutable_description.replace("attacker description")
    mutable_property.replace("attacker_property")
    mutable_scope.replace("admin")

    snapshot = prepare_registry
    assert_equal registry.name, snapshot.registry_name
    assert_equal %w[alpha.tool zeta.tool], snapshot.entries.map(&:name)
    assert_equal [ alpha.name, zeta.name ], snapshot.entries.map(&:class_name)

    zeta_entry = snapshot.entries.last
    assert_equal "Zeta description", zeta_entry.description
    assert_equal "string", zeta_entry.input_schema.dig("properties", "message", "type")
    assert_equal({ read_only_hint: true, open_world_hint: false }, zeta_entry.annotations)
    assert_equal [ "mcp" ], zeta_entry.scopes
    assert_deeply_frozen snapshot
    refute_contains_class snapshot
  end

  test "configuration accepts only a copied nonempty String and clears its snapshot" do
    registry = define_registry([ define_tool, [ "mcp" ] ])
    name = +registry.name

    assert_equal registry.name, (@configuration.registry = name)
    refute_same name, @configuration.registry
    assert_predicate @configuration.registry, :frozen?
    prepare_registry

    @configuration.registry = registry.name
    assert_raises(ArgumentError) { registry_snapshot }
    [ nil, "", 7, registry ].each do |invalid|
      assert_raises(ArgumentError) { @configuration.registry = invalid }
    end
  end

  test "registry rejects the complete invalid class and descriptor set" do
    assertions = {
      anonymous_tool: -> { registry_for_raw(Class.new(Hitch::MCP::Tool), [ "mcp" ]) },
      non_tool_class: -> { registry_for_raw(named_plain_class, [ "mcp" ]) },
      missing_tool_constant: lambda {
        tool = define_tool
        registry = define_registry([ tool, [ "mcp" ] ])
        HitchMcpRegistryFixtures.send(:remove_const, tool.name.split("::").last)
        registry
      },
      missing_name: -> { registry_for_tool(set_tool_name: false) },
      blank_name: -> { registry_for_tool(tool_name: "") },
      slash_name: -> { registry_for_tool(tool_name: "invalid/tool") },
      unicode_name: -> { registry_for_tool(tool_name: "inválid") },
      long_name: -> { registry_for_tool(tool_name: "a" * 65) },
      missing_description: -> { registry_for_tool(set_description: false) },
      blank_description: -> { registry_for_tool(description: " \t") },
      invalid_description_type: -> { registry_for_tool(description: 7) },
      missing_input_schema: -> { registry_for_tool(set_input_schema: false) },
      non_object_schema_document: -> { registry_for_tool(input_schema: []) },
      invalid_schema_type: -> { registry_for_tool(input_schema: { type: "bogus" }) },
      wrong_schema_dialect: lambda {
        registry_for_tool(input_schema: {
          "$schema" => "http://json-schema.org/draft-07/schema#",
          "type" => "object"
        })
      },
      external_ref: -> { registry_for_tool(input_schema: { "$ref" => "https://schemas.test/input" }) },
      unresolved_local_ref: -> { registry_for_tool(input_schema: { "$ref" => "#/$defs/missing" }) },
      malformed_pattern: -> { registry_for_tool(input_schema: { type: "object", patternProperties: { "[" => {} } }) },
      excessive_depth: -> { registry_for_tool(input_schema: deeply_nested_schema) },
      excessive_bytes: lambda {
        registry_for_tool(input_schema: { type: "object", description: "x" * 1_048_577 })
      },
      invalid_output_schema: -> { registry_for_tool(output_schema: { type: "bogus" }) },
      unsupported_annotation: -> { registry_for_tool(annotations: { audience: [ "user" ] }) },
      invalid_annotation_scalar: -> { registry_for_tool(annotations: { read_only_hint: "yes" }) },
      duplicate_annotation_alias: lambda {
        registry_for_tool(annotations: { read_only_hint: true, "readOnlyHint" => false })
      },
      explicit_server_context: lambda {
        registry_for_tool(input_schema: {
          type: "object",
          properties: { server_context: { type: "string" } }
        })
      },
      referenced_server_context: lambda {
        registry_for_tool(input_schema: {
          "$defs" => {
            args: {
              type: "object",
              properties: { server_context: { type: "string" } }
            }
          },
          "$ref" => "#/$defs/args"
        })
      },
      composed_server_context: lambda {
        registry_for_tool(input_schema: {
          allOf: [
            { type: "object" },
            { properties: { server_context: { type: "string" } } }
          ]
        })
      },
      call_override: -> { registry_for_tool(call_override: true) },
      missing_scopes: -> { registry_for_tool(scopes: nil) },
      empty_scopes: -> { registry_for_tool(scopes: []) },
      malformed_scope: -> { registry_for_tool(scopes: [ "invalid scope" ]) },
      duplicate_scopes: -> { registry_for_tool(scopes: %w[mcp mcp]) },
      unsupported_scope: -> { registry_for_tool(scopes: [ "admin" ]) }
    }

    assertions.each do |label, registry_builder|
      registry = registry_builder.call
      @configuration.registry = registry.name
      error = assert_raises(ArgumentError) { prepare_registry }
      assert_match(/mcp\.registry|input_schema|output_schema/, error.message, label)
      assert_raises(ArgumentError) { registry_snapshot }
    end
  end

  test "duplicate MCP names reject the entire registry" do
    first = define_tool(tool_name: "duplicate.name")
    second = define_tool(tool_name: "duplicate.name")
    registry = define_registry([ first, [ "mcp" ] ], [ second, [ "mcp" ] ])
    @configuration.registry = registry.name

    error = assert_raises(ArgumentError) { prepare_registry }
    assert_includes error.message, "duplicate tool names"
    assert_raises(ArgumentError) { registry_snapshot }
  end

  test "nested and patterned server_context data remains schema-valid" do
    tool = define_tool(input_schema: {
      type: "object",
      properties: {
        nested: {
          type: "object",
          properties: { server_context: { type: "string" } }
        }
      },
      patternProperties: { "^server_" => { type: "string" } },
      additionalProperties: true
    })
    registry = define_registry([ tool, [ "mcp" ] ])
    @configuration.registry = registry.name

    entry = prepare_registry.entries.fetch(0)
    assert entry.input_schema.dig("properties", "nested", "properties").key?("server_context")
    assert entry.input_schema.key?("patternProperties")
  end

  test "registry itself must be configured and resolve to its exact subclass" do
    assert @configuration.validate!
    @configuration.server_info = ->(_context) { { name: "fixture", version: "1" } }
    assert_raises(ArgumentError) { @configuration.validate! }

    @configuration.registry = "MissingRegistry"
    assert @configuration.validate!
    assert_raises(ArgumentError) { prepare_registry }

    plain = named_plain_class
    @configuration.registry = plain.name
    assert_raises(ArgumentError) { prepare_registry }

    @configuration.registry = "::#{plain.name}"
    assert_raises(ArgumentError) { prepare_registry }
  end

  private

  def define_tool(
    tool_name: nil,
    description: "A valid tool description",
    input_schema: VALID_INPUT_SCHEMA,
    output_schema: nil,
    annotations: nil,
    set_tool_name: true,
    set_description: true,
    set_input_schema: true,
    call_override: false
  )
    @sequence += 1
    klass = Class.new(Hitch::MCP::Tool)
    HitchMcpRegistryFixtures.const_set("Tool#{@sequence}", klass)
    klass.tool_name(tool_name || "fixture.tool#{@sequence}") if set_tool_name
    klass.description(description) if set_description
    klass.input_schema(input_schema) if set_input_schema
    klass.output_schema(output_schema) unless output_schema.nil?
    klass.annotations(annotations) unless annotations.nil?
    klass.define_singleton_method(:call) { |**| nil } if call_override
    klass
  end

  def define_registry(*registrations)
    @sequence += 1
    klass = Class.new(Hitch::MCP::Registry)
    HitchMcpRegistryFixtures.const_set("Registry#{@sequence}", klass)
    registrations.each { |tool, scopes| klass.register(tool, scopes:) }
    klass
  end

  def registry_for_tool(scopes: [ "mcp" ], **tool_options)
    define_registry([ define_tool(**tool_options), scopes ])
  end

  def registry_for_raw(value, scopes)
    define_registry([ value, scopes ])
  end

  def named_plain_class
    @sequence += 1
    Class.new.tap { |klass| HitchMcpRegistryFixtures.const_set("Plain#{@sequence}", klass) }
  end

  def deeply_nested_schema
    70.times.reduce({ type: "object" }) { |schema, _index| { allOf: [ schema ] } }
  end

  def prepare_registry
    @configuration.__send__(:prepare_registry!, supported_scopes: %w[mcp read])
  end

  def registry_snapshot
    @configuration.__send__(:registry_snapshot!)
  end

  def clear_fixtures
    HitchMcpRegistryFixtures.constants(false).each do |name|
      HitchMcpRegistryFixtures.send(:remove_const, name)
    end
  end

  def assert_deeply_frozen(value)
    assert_predicate value, :frozen?
    children = case value
    when Hash then value.flat_map { |key, child| [ key, child ] }
    when Array then value
    when Data then value.members.map { |member| value.public_send(member) }
    else []
    end
    children.each { |child| assert_deeply_frozen(child) }
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
