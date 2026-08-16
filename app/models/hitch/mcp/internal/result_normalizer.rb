# frozen_string_literal: true

require "json"
require "json_schemer"
require "mcp"

module Hitch
  module MCP
    module Internal
      # Converts the closed host Result into the one exact SDK response that was
      # independently schema-validated and measured before SDK validation.
      class ResultNormalizer
        JSON_SCHEMA_2020_12 = "https://json-schema.org/draft/2020-12/schema"
        ROOT_SCHEMA_KEYWORDS = %w[type $ref oneOf anyOf allOf not if const enum].freeze
        EXPLICIT_ERROR_MARKER = Object.new.freeze

        class Failure < StandardError
          attr_reader :category

          def initialize(category)
            @category = category
            super("Hitch MCP result normalization failed")
          end
        end

        class SDKResponse < ::MCP::Tool::Response
          def initialize(result, content_provided:)
            @hitch_result = result
            @hitch_content_provided = content_provided
          end

          def to_h
            copy(@hitch_result)
          end

          def content_provided?
            @hitch_content_provided
          end

          private

          def copy(value)
            JsonValues.copy(value)
          end
        end

        class << self
          def call(result:, output_schema:, max_bytes:)
            new(result, output_schema, max_bytes).call
          end

          def failure_category(error)
            error.category if error.instance_of?(Failure)
          end

          def explicit_error_text(result)
            return unless explicit_error?(result)

            content = read(result, :content)
            return unless content.is_a?(Array) && content.length == 1

            block = content.first
            return unless block.is_a?(Hash) && read(block, :type) == "text"

            text = read(block, :text)
            text if text.is_a?(String)
          end

          private

          def explicit_error?(result)
            meta = read(result, :_meta)
            meta.is_a?(Hash) && meta.key?(EXPLICIT_ERROR_MARKER) &&
              meta.fetch(EXPLICIT_ERROR_MARKER).equal?(EXPLICIT_ERROR_MARKER)
          end

          def read(hash, key)
            JsonValues.read(hash, key)
          end
        end

        def initialize(result, output_schema, max_bytes)
          @result = result
          @output_schema = output_schema
          @max_bytes = max_bytes
        end

        def call
          invalid!(:invalid_result_type) unless result.instance_of?(Result)
          invalid!(:invalid_result_limit) unless max_bytes.instance_of?(Integer) && max_bytes.positive?

          canonical, content_provided, explicit_error = canonical_result
          serialized = generate(canonical)
          invalid!(:result_too_large) if serialized.bytesize > max_bytes

          sdk_result = if explicit_error
            canonical.merge(_meta: { EXPLICIT_ERROR_MARKER => EXPLICIT_ERROR_MARKER }.freeze).freeze
          else
            canonical
          end
          SDKResponse.new(sdk_result, content_provided:)
        rescue SystemStackError
          invalid!(:serialization_failure)
        end

        private

        attr_reader :result, :output_schema, :max_bytes

        def canonical_result
          case result.__send__(:kind)
          when :text then text_result
          when :structured then structured_result
          when :error then error_result
          else invalid!(:invalid_result_type)
          end
        end

        def text_result
          validate_output_schema!(nil) if output_schema
          content = text_content(result.__send__(:value))
          [ deep_freeze(content: content, isError: false), true, false ]
        end

        def structured_result
          invalid!(:missing_output_schema) unless output_schema

          value = result.__send__(:value)
          serialized_value = generate(value)
          validate_output_schema!(value)
          text = result.__send__(:text)
          fallback = value.is_a?(Hash) ? nil : serialized_value
          content = text || fallback
          canonical = {
            content: content ? text_content(content) : [],
            isError: false,
            structuredContent: value
          }
          [ deep_freeze(canonical), !content.nil?, false ]
        end

        def error_result
          content = text_content(result.__send__(:value))
          [ deep_freeze(content: content, isError: true), true, true ]
        end

        def validate_output_schema!(value)
          schema = normalized_output_schema
          schema = schema.merge("type" => "object") unless ROOT_SCHEMA_KEYWORDS.any? { |key| schema.key?(key) }
          resolver = ->(uri) { raise JSONSchemer::UnknownRef, uri.to_s }
          schemer = JSONSchemer.schema(
            schema,
            meta_schema: JSON_SCHEMA_2020_12,
            format: false,
            ref_resolver: resolver,
            regexp_resolver: "ruby"
          )
          invalid!(:output_schema_mismatch) unless schemer.valid?(value)
        rescue Failure
          raise
        rescue StandardError
          invalid!(:output_schema_validation_failure)
        end

        def normalized_output_schema
          parsed = JSON.parse(generate(output_schema))
          invalid!(:output_schema_validation_failure) unless parsed.is_a?(Hash)

          parsed
        end

        def generate(value)
          JSON.generate(value, max_nesting: false)
        rescue JSON::GeneratorError, EncodingError
          invalid!(:serialization_failure)
        end

        def text_content(text)
          [ { type: "text", text: text } ]
        end

        def deep_freeze(value)
          JsonValues.deep_freeze(value)
        end

        def invalid!(category)
          raise Failure, category
        end

        private_constant :Failure, :SDKResponse, :EXPLICIT_ERROR_MARKER
      end
    end
  end
end
