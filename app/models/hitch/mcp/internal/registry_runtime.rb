# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Validates Registry declarations into the persistent snapshot at
      # prepare time and resolves listings and calls against it per request.
      # The snapshot retains only class names and frozen data.
      class RegistryRuntime
        CONSTANT_NAME_PATTERN = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
        OAUTH_SCOPE_PATTERN = /\A[\x21\x23-\x5B\x5D-\x7E]+\z/
        MAX_SCOPE_BYTES = 64
        ANNOTATION_KEYS = {
          "title" => :title,
          "readOnlyHint" => :read_only_hint,
          "read_only_hint" => :read_only_hint,
          "destructiveHint" => :destructive_hint,
          "destructive_hint" => :destructive_hint,
          "idempotentHint" => :idempotent_hint,
          "idempotent_hint" => :idempotent_hint,
          "openWorldHint" => :open_world_hint,
          "open_world_hint" => :open_world_hint
        }.freeze

        Entry = Data.define(
          :class_name,
          :name,
          :description,
          :input_schema,
          :output_schema,
          :annotations,
          :scopes,
          # The SDK tool wrapper (anonymous ::MCP::Tool subclass) compiled once
          # here at prepare time instead of per tool per request. It holds only
          # frozen entry data — never the reloadable host tool class.
          :sdk_tool
        )
        Snapshot = Data.define(:registry_name, :entries)
        CallResolution = Data.define(:status, :tool, :required_scopes)
        RuntimeTool = Data.define(:entry, :tool_class) do
          def name = entry.name
          def description = entry.description
          def input_schema = entry.input_schema
          def output_schema = entry.output_schema
          def annotations = entry.annotations
          def sdk_tool = entry.sdk_tool

          def call(server_context:, **arguments)
            tool_class.call(server_context:, **arguments)
          end
        end

        class << self
          def build_snapshot(registry_name:, supported_scopes:)
            registry_class = resolve_named_constant(registry_name, "registry")
            unless registry_class.is_a?(Class) && registry_class < Registry
              raise ArgumentError, "mcp.registry must resolve to a Hitch::MCP::Registry subclass"
            end

            supported = validate_supported_scopes(supported_scopes)
            entries = registry_class.declarations.each_with_index.map do |declaration, index|
              build_entry(declaration, index:, supported_scopes: supported)
            end
            duplicate_names = entries.map(&:name).tally.select { |_name, count| count > 1 }.keys
            unless duplicate_names.empty?
              raise ArgumentError, "mcp.registry contains duplicate tool names: #{duplicate_names.sort.join(', ')}"
            end

            Snapshot.new(
              registry_name: registry_name.dup.freeze,
              entries: entries.sort_by(&:name).freeze
            )
          rescue NameError
            raise ArgumentError, "mcp.registry or one of its tools could not be resolved"
          end

          def runtime_listing(snapshot:, context:)
            validate_snapshot!(snapshot)

            snapshot.entries.filter_map do |entry|
              runtime_tool = available_runtime_tool(entry, context)
              runtime_tool if runtime_tool && scopes_granted?(entry.scopes, context)
            end.freeze
          end

          def runtime_call(snapshot:, name:, context:)
            validate_snapshot!(snapshot)
            entry = snapshot.entries.find { |candidate| candidate.name == name }
            return hidden_call_resolution unless entry

            runtime_tool = available_runtime_tool(entry, context)
            return hidden_call_resolution unless runtime_tool

            unless scopes_granted?(entry.scopes, context)
              return CallResolution.new(
                status: :insufficient_scope,
                tool: nil,
                required_scopes: entry.scopes
              )
            end

            CallResolution.new(
              status: :available,
              tool: runtime_tool,
              required_scopes: [].freeze
            )
          end

          private

          def available_runtime_tool(entry, context)
            tool_class = resolve_named_constant(entry.class_name, "mcp.registry tool")
            unless tool_class.is_a?(Class) && tool_class < Tool &&
                tool_class.name == entry.class_name && tool_class.tool_name == entry.name &&
                tool_class.method(:call).owner == Tool.singleton_class
              raise ArgumentError, "MCP registry is unavailable"
            end

            available = tool_class.available_to?(context)
            unless available == true || available == false
              raise ArgumentError, "MCP tool availability must return a Boolean"
            end
            return unless available

            RuntimeTool.new(entry:, tool_class:)
          rescue NameError
            raise ArgumentError, "MCP registry is unavailable"
          end

          def scopes_granted?(required_scopes, context)
            granted_scopes = context.granted_scopes
            unless granted_scopes.instance_of?(Array) && granted_scopes.all?(String)
              raise ArgumentError, "MCP context scopes are unavailable"
            end

            required_scopes.all? { |scope| granted_scopes.include?(scope) }
          end

          def hidden_call_resolution
            CallResolution.new(status: :hidden, tool: nil, required_scopes: [].freeze)
          end

          def validate_snapshot!(snapshot)
            raise ArgumentError, "MCP registry is unavailable" unless snapshot.instance_of?(Snapshot)
          end

          def build_entry(declaration, index:, supported_scopes:)
            label = "mcp.registry entry #{index + 1}"
            class_name = declaration.class_name
            unless class_name.is_a?(String) && CONSTANT_NAME_PATTERN.match?(class_name)
              raise ArgumentError, "#{label} must register a named Hitch::MCP::Tool class"
            end

            tool_class = resolve_named_constant(class_name, "#{label} tool")
            unless tool_class.is_a?(Class) && tool_class < Tool
              raise ArgumentError, "#{label} must register a Hitch::MCP::Tool subclass"
            end
            unless tool_class.method(:call).owner == Tool.singleton_class
              raise ArgumentError, "#{label} must not override framework-owned .call"
            end

            name = validate_tool_name(tool_class.tool_name, label)
            description = validate_description(tool_class.description, label)
            input_schema = SchemaContract.new(
              tool_class.input_schema,
              label: "#{label} input_schema"
            ).call
            output_schema = if tool_class.output_schema.nil?
              nil
            else
              SchemaContract.new(
                tool_class.output_schema,
                label: "#{label} output_schema"
              ).call
            end
            annotations = validate_annotations(tool_class.annotations, label)
            scopes = validate_scopes(declaration.scopes, label, supported_scopes)

            Entry.new(
              class_name: class_name.dup.freeze,
              name:,
              description:,
              input_schema:,
              output_schema:,
              annotations:,
              scopes:,
              sdk_tool: SDKAdapter.build_sdk_tool(
                name:, description:, input_schema:, output_schema:, annotations:
              )
            )
          end

          def validate_tool_name(value, label)
            unless Protocol.tool_name?(value)
              raise ArgumentError,
                "#{label} tool_name must be 1-#{Protocol::MAX_TOOL_NAME_LENGTH} ASCII letters, " \
                  "digits, underscore, dot, or dash"
            end

            value.dup.freeze
          end

          def validate_description(value, label)
            unless value.is_a?(String) && value.match?(/\S/)
              raise ArgumentError, "#{label} description must be a nonblank String"
            end

            value.dup.freeze
          end

          def validate_annotations(value, label)
            return if value.nil?
            raise ArgumentError, "#{label} annotations must be a Hash" unless value.is_a?(Hash)

            value.each_with_object({}) do |(key, annotation_value), normalized|
              canonical = ANNOTATION_KEYS[key.to_s]
              raise ArgumentError, "#{label} contains an unsupported annotation" unless canonical
              raise ArgumentError, "#{label} contains a duplicate annotation" if normalized.key?(canonical)

              normalized[canonical] = if canonical == :title
                unless annotation_value.is_a?(String) && annotation_value.match?(/\S/)
                  raise ArgumentError, "#{label} annotation title must be a nonblank String"
                end
                annotation_value.dup.freeze
              else
                unless annotation_value == true || annotation_value == false
                  raise ArgumentError, "#{label} tool hint annotations must be Boolean"
                end
                annotation_value
              end
            end.freeze
          end

          def validate_scopes(scopes, label, supported_scopes)
            unless scopes.is_a?(Array) && !scopes.empty?
              raise ArgumentError, "#{label} scopes must be a nonempty Array"
            end
            unless scopes.all? do |scope|
              scope.is_a?(String) && scope.bytesize <= MAX_SCOPE_BYTES && OAUTH_SCOPE_PATTERN.match?(scope)
            end
              raise ArgumentError, "#{label} scopes must contain valid OAuth scope tokens"
            end
            unless scopes.uniq.length == scopes.length
              raise ArgumentError, "#{label} scopes must not contain duplicates"
            end

            unsupported = scopes - supported_scopes
            unless unsupported.empty?
              raise ArgumentError, "#{label} scopes are not present in Hitch.configuration.supported_scopes"
            end

            scopes.map { |scope| scope.dup.freeze }.freeze
          end

          def validate_supported_scopes(scopes)
            unless scopes.is_a?(Array) && scopes.all?(String)
              raise ArgumentError, "supported_scopes must be an Array of Strings"
            end

            scopes
          end

          def resolve_named_constant(name, label)
            unless name.is_a?(String) && CONSTANT_NAME_PATTERN.match?(name)
              raise ArgumentError, "#{label} must be a named constant"
            end

            constant = name.split("::").reduce(Object) do |namespace, part|
              raise NameError, part unless namespace.is_a?(Module)

              namespace.const_get(part, false)
            end
            unless constant.respond_to?(:name) && constant.name == name
              raise ArgumentError, "#{label} must resolve to its exact named constant"
            end

            constant
          end
        end
      end
    end
  end
end
