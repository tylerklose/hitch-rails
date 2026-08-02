# frozen_string_literal: true

require "mcp"

module Hitch
  module Conformance
    module Server
      module FixtureTools
        EMPTY_SCHEMA = {
          "type" => "object",
          "properties" => {}.freeze,
          "additionalProperties" => false
        }.freeze
        JSON_SCHEMA_2020_12 = {
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "object",
          "$defs" => {
            "address" => {
              "$anchor" => "addressDef",
              "type" => "object",
              "properties" => {
                "street" => { "type" => "string" }.freeze,
                "city" => { "type" => "string" }.freeze
              }.freeze
            }.freeze
          }.freeze,
          "properties" => {
            "name" => { "type" => "string" }.freeze,
            "address" => { "$ref" => "#/$defs/address" }.freeze,
            "contactMethod" => { "type" => "string", "enum" => %w[phone email].freeze }.freeze,
            "phone" => { "type" => "string" }.freeze,
            "email" => { "type" => "string" }.freeze
          }.freeze,
          "allOf" => [ { "anyOf" => [
            { "required" => [ "phone" ].freeze }.freeze,
            { "required" => [ "email" ].freeze }.freeze
          ].freeze }.freeze ].freeze,
          "if" => {
            "properties" => { "contactMethod" => { "const" => "phone" }.freeze }.freeze,
            "required" => [ "contactMethod" ].freeze
          }.freeze,
          "then" => { "required" => [ "phone" ].freeze }.freeze,
          "else" => { "required" => [ "email" ].freeze }.freeze,
          "additionalProperties" => false
        }.freeze
        DEFINITIONS = {
          "test_simple_text" => [ "Return the official conformance simple-text fixture", EMPTY_SCHEMA ].freeze,
          "test_error_handling" => [ "Return the official conformance tool-error fixture", EMPTY_SCHEMA ].freeze,
          "json_schema_2020_12_tool" => [ "Tool with JSON Schema 2020-12 features", JSON_SCHEMA_2020_12 ].freeze,
          "test_streaming_elicitation" => [ "Return one complete response for stateless stream inspection", EMPTY_SCHEMA ].freeze,
          "test_logging_tool" => [ "Return without emitting a logging notification", EMPTY_SCHEMA ].freeze
        }.freeze
        DIAGNOSTICS = {
          "test_missing_capability" => [
            "Runner-only probe for the reviewed missing-capability baseline",
            EMPTY_SCHEMA
          ].freeze
        }.freeze

        class Definition
          def initialize(name, description, input_schema, on_invoke)
            @name = name
            @description = description
            @input_schema = input_schema
            @on_invoke = on_invoke
          end

          attr_reader :name, :description, :input_schema

          def output_schema = nil

          def annotations
            {
              read_only_hint: true,
              destructive_hint: false,
              idempotent_hint: true,
              open_world_hint: false
            }.freeze
          end

          def call(server_context:, **arguments)
            @on_invoke.call
            if name == "test_error_handling"
              return ::MCP::Tool::Response.new(
                [ { type: "text", text: "This tool intentionally returns an error for testing" } ],
                error: true
              )
            end

            text = if name == "test_simple_text"
              "This is a simple text response for testing."
            else
              "Conformance fixture completed."
            end
            ::MCP::Tool::Response.new([ { type: "text", text: text } ])
          end
        end
        private_constant :Definition

        def self.all(on_invoke: -> { })
          DEFINITIONS.map do |name, (description, schema)|
            Definition.new(name, description, schema, on_invoke)
          end.freeze
        end

        def self.runner_diagnostics(on_invoke: -> { })
          DIAGNOSTICS.map do |name, (description, schema)|
            Definition.new(name, description, schema, on_invoke)
          end.freeze
        end
      end
    end
  end
end
