# frozen_string_literal: true

module Hitch
  module Generators
    # Pre-flight guards shared by Hitch generators: check the destination
    # before writing so a refused run leaves no partial install behind.
    # Including generators define +refusal_subject+.
    module GeneratorGuards
      REGISTRY_PATH = "app/tools/mcp_tool_registry.rb"

      private

      def constant_collision?(name)
        return false unless Object.const_defined?(name, false)
        return true if File.expand_path(destination_root) == File.expand_path(Rails.root)

        source = Object.const_source_location(name, false)&.first
        source && File.expand_path(source).start_with?("#{File.expand_path(destination_root)}/")
      rescue NameError
        false
      end

      def destination_file?(relative_path)
        File.file?(destination_path(relative_path))
      end

      def destination_path(relative_path)
        File.expand_path(relative_path, destination_root)
      end

      def refuse!(operation, errors)
        raise ::Thor::Error, "#{refusal_subject} #{operation} refused:\n- #{errors.join("\n- ")}"
      end
    end
  end
end
