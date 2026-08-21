# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Validates the host's mcp.server_info result into the frozen,
      # string-keyed identity hash the SDK boundary requires.
      module ServerInfo
        KEY_MAP = {
          "name" => "name",
          "version" => "version",
          "title" => "title",
          "instructions" => "instructions",
          name: "name",
          version: "version",
          title: "title",
          instructions: "instructions"
        }.freeze

        module_function

        def normalize(value)
          raise ArgumentError, "mcp.server_info must return a Hash" unless value.is_a?(Hash)

          unknown = value.keys - KEY_MAP.keys
          raise ArgumentError, "mcp.server_info contains unsupported keys" unless unknown.empty?

          canonical_keys = value.keys.map { |key| KEY_MAP.fetch(key) }
          raise ArgumentError, "mcp.server_info contains duplicate keys" unless canonical_keys.uniq == canonical_keys

          normalized = value.to_h do |key, field|
            [ KEY_MAP.fetch(key).dup.freeze, string_field(field) ]
          end
          %w[name version].each do |required|
            field = normalized[required]
            raise ArgumentError, "mcp.server_info requires name and version" unless field.is_a?(String) && !field.empty?
          end
          normalized.freeze
        end

        def string_field(value)
          raise ArgumentError, "mcp.server_info values must be strings" unless value.is_a?(String)

          value.dup.freeze
        end
      end
    end
  end
end
