# frozen_string_literal: true

module McpTools
  class Echo < Hitch::MCP::Tool
    if ENV["HITCH_DOCTOR_EARLY_LOAD_PROBE"]
      raise "Doctor loaded its registry before initialization" unless Rails.application.initialized?

      MODEL_TRANSLATION = ActiveModel::Translation
      RECORD_BASE = ActiveRecord::Base
    end

    tool_name "dummy.echo"
    description "Describe the dummy application's registered echo tool"
    input_schema(
      type: "object",
      properties: {
        message: { type: "string", maxLength: 1_000 }
      },
      required: [ "message" ],
      additionalProperties: false
    )
    annotations read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false

    def self.available_to?(context)
      !context.principal.nil?
    end
  end
end
