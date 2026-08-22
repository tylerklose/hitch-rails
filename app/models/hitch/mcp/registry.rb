# frozen_string_literal: true

module Hitch
  module MCP
    # Explicit host allowlist for MCP tools. Subclasses declare named Tool
    # classes; Internal::RegistryRuntime validates the declarations into a
    # persistent snapshot and resolves tools per request.
    class Registry
      Declaration = Data.define(:class_name, :scopes, :source)

      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@hitch_mcp_declarations, [].freeze)
        end

        def register(tool_class = nil, scopes: nil)
          declaration = Declaration.new(
            class_name: declaration_class_name(tool_class),
            scopes: declaration_scopes(scopes),
            source: declaration_source(tool_class)
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

        # What the host actually wrote, kept for the boot error that fires
        # when it was not a named class. By then class_name is already nil and
        # only the entry's position is left, which makes a host with a dozen
        # tools count down a list to find their own typo.
        def declaration_source(tool_class)
          case tool_class
          when nil then "no argument"
          when Class then named_or(tool_class, "an anonymous class")
          when Module then named_or(tool_class, "an anonymous module")
          else "#{tool_class.inspect} (a #{tool_class.class})"
          end
        rescue StandardError
          # inspect is host code on an arbitrary object; a registry mistake
          # must not surface as some unrelated exception from this method.
          "a #{tool_class.class}"
        end

        def named_or(mod, fallback)
          name = mod.name
          name.is_a?(String) && !name.empty? ? name : fallback
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
