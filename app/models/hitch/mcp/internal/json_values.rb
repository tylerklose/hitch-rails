# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Shared recursive helpers for the JSON-value structures that cross MCP
      # boundaries. Keys are never symbolized (INV-MCP-007).
      module JsonValues
        module_function

        # String/Symbol-indifferent read that prefers the key exactly as given.
        def read(hash, key)
          return unless hash.is_a?(Hash)
          return hash[key] if hash.key?(key)

          hash[key.is_a?(Symbol) ? key.to_s : key.to_sym]
        end

        def copy(value)
          case value
          when Hash then value.to_h { |key, child| [ key, copy(child) ] }
          when Array then value.map { |child| copy(child) }
          when String then value.dup
          else value
          end
        end

        def deep_string_copy_and_freeze(value)
          copied = case value
          when Hash
            value.to_h { |key, child| [ key.to_s.freeze, deep_string_copy_and_freeze(child) ] }
          when Array
            value.map { |child| deep_string_copy_and_freeze(child) }
          when String
            value.dup
          else
            value
          end
          copied.freeze
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, child| deep_freeze(key); deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          end
          value.freeze
        end
      end
    end
  end
end
