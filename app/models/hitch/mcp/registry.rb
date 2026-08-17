# frozen_string_literal: true

module Hitch
  module MCP
    # Explicit host allowlist for MCP tools. Subclasses declare named Tool
    # classes; Internal::RegistryRuntime validates the declarations into a
    # persistent snapshot and resolves tools per request.
    class Registry
      Declaration = Data.define(:class_name, :scopes)

      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@hitch_mcp_declarations, [].freeze)
        end

        def register(tool_class = nil, scopes: nil)
          declaration = Declaration.new(
            class_name: declaration_class_name(tool_class),
            scopes: declaration_scopes(scopes)
          )
          @hitch_mcp_declarations = (declarations + [ declaration ]).freeze
          tool_class
        end

        def declarations
          @hitch_mcp_declarations ||= [].freeze
        end

        private

        def declaration_class_name(tool_class)
          name = tool_class.name if tool_class.respond_to?(:name)
          name.is_a?(String) && !name.empty? ? name.dup.freeze : nil
        end

        def declaration_scopes(scopes)
          return unless scopes.is_a?(Array)

          scopes.map { |scope| scope.is_a?(String) ? scope.dup.freeze : nil }.freeze
        end
      end

      private_constant :Declaration
    end
  end
end
