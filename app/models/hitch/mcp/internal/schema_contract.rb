# frozen_string_literal: true

require "json"
require "json_schemer"
require "uri"

module Hitch
  module MCP
    module Internal
      # Admission-time contract for a tool's input or output schema: a bounded,
      # copied, frozen JSON Schema 2020-12 document with only same-document
      # references.
      class SchemaContract
        MAX_SCHEMA_DEPTH = 64
        MAX_SCHEMA_OBJECTS = 10_000
        MAX_SCHEMA_BYTES = 1_048_576
        JSON_SCHEMA_2020_12 = "https://json-schema.org/draft/2020-12/schema"
        REFERENCE_KEYS = %w[$ref $dynamicRef].freeze

        def initialize(value, label:)
          @label = label
          @schema = copy_schema(value)
        end

        def call
          invalid!("must be a JSON object") unless @schema.instance_of?(Hash)
          invalid!("exceeds #{MAX_SCHEMA_BYTES} serialized bytes") if serialized_bytes > MAX_SCHEMA_BYTES

          validate_dialects_and_references!
          validate_json_schema!

          @schema
        end

        private

        attr_reader :label

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
