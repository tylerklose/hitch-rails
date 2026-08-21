# frozen_string_literal: true

require "json"
require "json_schemer"
require "set"
require "uri"

module Hitch
  module MCP
    module Internal
      # Admission-time contract for a tool's input or output schema: a bounded,
      # copied, frozen JSON Schema 2020-12 document with only same-document
      # references, never declaring the reserved top-level server_context input.
      class SchemaContract
        MAX_SCHEMA_DEPTH = 64
        MAX_SCHEMA_OBJECTS = 10_000
        MAX_SCHEMA_BYTES = 1_048_576
        JSON_SCHEMA_2020_12 = "https://json-schema.org/draft/2020-12/schema"
        REFERENCE_KEYS = %w[$ref $dynamicRef].freeze
        SAME_INSTANCE_SCHEMA_KEYS = %w[if then else].freeze
        SAME_INSTANCE_SCHEMA_ARRAY_KEYS = %w[allOf anyOf oneOf].freeze

        def initialize(value, label:, input:)
          @label = label
          @input = input
          @schema = copy_schema(value)
        end

        def call
          invalid!("must be a JSON object") unless @schema.instance_of?(Hash)
          invalid!("exceeds #{MAX_SCHEMA_BYTES} serialized bytes") if serialized_bytes > MAX_SCHEMA_BYTES

          validate_dialects_and_references!
          validate_json_schema!
          if input && explicitly_declares_property?(@schema, "server_context", Set.new)
            invalid!("must not explicitly declare the top-level server_context property")
          end

          @schema
        end

        private

        attr_reader :label, :input

        def copy_schema(value)
          JsonValues.copy(
            value,
            keys: :stringify_symbols, symbols: :to_s, foreign: :reject,
            finite: true, duplicates: :reject, freeze: true,
            max_depth: MAX_SCHEMA_DEPTH, max_objects: MAX_SCHEMA_OBJECTS,
            on_invalid: method(:copy_invalid!)
          )
        end

        def copy_invalid!(reason, detail)
          invalid!(
            case reason
            when :depth then "nesting exceeds #{MAX_SCHEMA_DEPTH}"
            when :recursive then "contains a recursive Ruby object"
            when :objects then "exceeds #{MAX_SCHEMA_OBJECTS} schema objects"
            when :key then "contains a non-string schema key"
            when :duplicate_key then "contains duplicate key #{detail.inspect}"
            when :non_finite then "contains a non-finite number"
            else "contains a non-JSON value"
            end
          )
        end

        def serialized_bytes
          JSON.generate(@schema, max_nesting: false).bytesize
        rescue JSON::GeneratorError
          invalid!("cannot be serialized as JSON")
        end

        def validate_dialects_and_references!
          each_schema_value(@schema) do |node|
            next unless node.is_a?(Hash)

            dialect = node["$schema"]
            if dialect && dialect != JSON_SCHEMA_2020_12
              invalid!("must use JSON Schema 2020-12")
            end

            REFERENCE_KEYS.each do |key|
              next unless node.key?(key)

              reference = node[key]
              unless reference.is_a?(String) && reference.start_with?("#")
                invalid!("supports only same-document #{key} values")
              end
              resolve_local_reference(reference)
            end
          end
        end

        def validate_json_schema!
          resolver = lambda do |uri|
            raise JSONSchemer::UnknownRef, uri.to_s
          end
          schemer = JSONSchemer.schema(
            @schema,
            meta_schema: JSON_SCHEMA_2020_12,
            format: false,
            ref_resolver: resolver,
            regexp_resolver: "ruby"
          )
          errors = schemer.validate_schema.to_a
          invalid!("is not a valid JSON Schema 2020-12 document") unless errors.empty?
        rescue JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer,
          JSONSchemer::UnknownRef, RegexpError, URI::InvalidURIError
          invalid!("is not a valid JSON Schema 2020-12 document")
        end

        def explicitly_declares_property?(schema, property, visited)
          return false unless schema.is_a?(Hash)
          return false if visited.include?(schema.object_id)

          visited.add(schema.object_id)
          properties = schema["properties"]
          return true if properties.is_a?(Hash) && properties.key?(property)

          REFERENCE_KEYS.each do |key|
            reference = schema[key]
            return true if reference && explicitly_declares_property?(
              resolve_local_reference(reference), property, visited
            )
          end

          SAME_INSTANCE_SCHEMA_KEYS.each do |key|
            return true if explicitly_declares_property?(schema[key], property, visited)
          end
          SAME_INSTANCE_SCHEMA_ARRAY_KEYS.each do |key|
            return true if Array(schema[key]).any? do |child|
              explicitly_declares_property?(child, property, visited)
            end
          end
          dependent_schemas = schema["dependentSchemas"]
          dependent_schemas.is_a?(Hash) && dependent_schemas.any? do |_trigger, child|
            explicitly_declares_property?(child, property, visited)
          end
        end

        def resolve_local_reference(reference)
          fragment = reference.delete_prefix("#")
          return @schema if fragment.empty?

          decoded = URI::DEFAULT_PARSER.unescape(fragment)
          invalid!("contains an invalid local reference") unless decoded.valid_encoding?

          if decoded.start_with?("/")
            decoded.split("/", -1).drop(1).reduce(@schema) do |node, token|
              key = token.gsub(/~1/, "/").gsub(/~0/, "~")
              case node
              when Hash
                invalid!("contains an unresolved local reference") unless node.key?(key)
                node.fetch(key)
              when Array
                index = Integer(key, exception: false)
                invalid!("contains an unresolved local reference") unless index && index >= 0 && index < node.length
                node.fetch(index)
              else
                invalid!("contains an unresolved local reference")
              end
            end
          else
            anchor = find_anchor(@schema, decoded)
            invalid!("contains an unresolved local reference") unless anchor
            anchor
          end
        rescue ArgumentError
          invalid!("contains an invalid local reference")
        end

        def find_anchor(value, name)
          case value
          when Hash
            return value if value["$anchor"] == name || value["$dynamicAnchor"] == name

            value.each_value do |child|
              found = find_anchor(child, name)
              return found if found
            end
          when Array
            value.each do |child|
              found = find_anchor(child, name)
              return found if found
            end
          end
          nil
        end

        def each_schema_value(value, &block)
          yield value
          case value
          when Hash
            value.each_value { |child| each_schema_value(child, &block) }
          when Array
            value.each { |child| each_schema_value(child, &block) }
          end
        end

        def invalid!(reason)
          raise ArgumentError, "#{label} #{reason}"
        end
      end
    end
  end
end
