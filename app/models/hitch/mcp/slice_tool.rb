# frozen_string_literal: true

module Hitch
  module MCP
    # The single read-only tool used to prove the authenticated M2 transport.
    # It is removed when the host-owned Registry becomes the only admission
    # path in M3 and is not an adopter extension point.
    class SliceTool
      NAME = "hitch.echo"
      DESCRIPTION = "Echo one bounded message through the authenticated Hitch transport"
      INPUT_SCHEMA = {
        "type" => "object",
        "required" => [ "message" ].freeze,
        "properties" => {
          "message" => { "type" => "string", "maxLength" => 1_000 }.freeze,
          "nested" => { "type" => "object" }.freeze
        }.freeze,
        "additionalProperties" => true
      }.freeze

      def initialize(on_invoke: -> { })
        @on_invoke = on_invoke
      end

      def name = NAME
      def description = DESCRIPTION
      def input_schema = INPUT_SCHEMA
      def output_schema = nil
      def annotations
        {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }.freeze
      end

      def call(arguments:, context:)
        @on_invoke.call
        message = arguments.fetch("message")
        ::MCP::Tool::Response.new(
          [ { type: "text", text: message } ],
          structured_content: { "message" => message }
        )
      end
    end

    private_constant :SliceTool
  end
end
