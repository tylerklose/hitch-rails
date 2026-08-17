# frozen_string_literal: true

require "json"
require "json_schemer"

module Hitch
  module MCP
    module Internal
      # Converts the closed host Result into the one exact SDK response that was
      # independently schema-validated and measured before SDK validation.
      class ResultNormalizer
        JSON_SCHEMA_2020_12 = "https://json-schema.org/draft/2020-12/schema"
        ROOT_SCHEMA_KEYWORDS = %w[type $ref oneOf anyOf allOf not if const enum].freeze

        class Failure < StandardError
          attr_reader :category

          def initialize(category)
            @category = category
            super("Hitch MCP result normalization failed")
          end
        end

        # Duck-typed stand-in for ::MCP::Tool::Response — both supported SDK
        # lines read only #to_h and #content_provided?. explicit_error_text is
        # the host-authored Result.error string, carried out of band so the
        # response normalizer can tell it apart from SDK-generated errors.
        class SDKResponse
          attr_reader :explicit_error_text

          def initialize(result, content_provided:, explicit_error_text: nil)
            @hitch_result = result
            @hitch_content_provided = content_provided
            @explicit_error_text = explicit_error_text
          end

          def to_h
            JsonValues.copy(@hitch_result)
          end

          def content_provided?
            @hitch_content_provided
          end
        end

        class << self
          def call(result:, output_schema:, max_bytes:)
            new(result, output_schema, max_bytes).call
          end

          def failure_category(error)
            error.category if error.instance_of?(Failure)
          end

          def explicit_error_text(response)
            response.explicit_error_text if response.instance_of?(SDKResponse)
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

          canonical, content_provided, explicit_error_text = canonical_result
          serialized = generate(canonical)
          invalid!(:result_too_large) if serialized.bytesize > max_bytes

          SDKResponse.new(canonical, content_provided:, explicit_error_text:)
        rescue SystemStackError
          invalid!(:serialization_failure)
        end

        private

        attr_reader :result, :output_schema, :max_bytes

        def canonical_result
          case result.kind
          when :text then text_result
          when :structured then structured_result
          when :error then error_result
          else invalid!(:invalid_result_type)
          end
        end

        def text_result
          validate_output_schema!(nil) if output_schema
          content = text_content(result.value)
          [ deep_freeze(content: content, isError: false), true, nil ]
        end

        def structured_result
          invalid!(:missing_output_schema) unless output_schema

          value = result.value
          serialized_value = generate(value)
          validate_output_schema!(value)
          text = result.text
          fallback = value.is_a?(Hash) ? nil : serialized_value
          content = text || fallback
          canonical = {
            content: content ? text_content(content) : [],
            isError: false,
            structuredContent: value
          }
          [ deep_freeze(canonical), !content.nil?, nil ]
        end

        def error_result
          text = result.value
          [ deep_freeze(content: text_content(text), isError: true), true, text ]
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

        private_constant :Failure, :SDKResponse
      end
    end
  end
end
