# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "rails/generators"
require_relative "generator_guards"

module Hitch
  module Generators
    # Generates a working, registered MCP tool plus an integration test that
    # proves it responds over real HTTP. --deny-default emits a hardened
    # variant instead: unavailable, denying, and unimplemented until the
    # host fills it in.
    #
    # Usage:
    #   bin/rails generate hitch:tool NAME
    #   bin/rails destroy hitch:tool NAME
    class ToolGenerator < ::Rails::Generators::Base
      include Hitch::Generators::GeneratorGuards

      namespace "hitch:tool"

      source_root File.expand_path("tool/templates", __dir__)

      argument :name, type: :string, required: true,
        desc: "Tool name, optionally nested with / or ::"
      class_option :namespace,
        type: :string,
        default: "McpTools",
        desc: "Root Ruby namespace for the generated tool"
      class_option :deny_default,
        type: :boolean,
        default: false,
        desc: "Generate the hardened variant: unavailable and denying until implemented"

      NAME_SEGMENT_PATTERN =
        /\A(?:[a-z][a-z0-9]*(?:[_-][a-z0-9]+)*|[A-Z][A-Za-z0-9]*)\z/
      CANONICAL_SEGMENT_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
      NAMESPACE_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
      REGISTRY_PATH = "app/tools/mcp_tool_registry.rb"

      def self.exit_on_failure?
        true
      end

      def generate_or_revoke
        prepare_identity!
        preflight! unless behavior == :revoke

        template "tool.rb.tt", @tool_path
        template "tool_test.rb.tt", @test_path
        inject_into_class REGISTRY_PATH, "McpToolRegistry", "  #{@registration_line}\n"

        print_next_steps unless behavior == :revoke
      end

      private

      def preflight!
        errors = []
        [ @tool_path, @test_path ].each do |path|
          errors << "file collision: #{path}" if destination_file?(path)
        end
        errors << "constant collision: #{@class_name}" if constant_collision?(@class_name)
        errors << "constant collision: #{@test_class_name}" if constant_collision?(@test_class_name)
        errors << "#{REGISTRY_PATH} is missing; run `bin/rails generate hitch:install` first" unless
          destination_file?(REGISTRY_PATH)
        refuse!("generation", errors) if errors.any?
      end

      def prepare_identity!
        namespace = options.fetch("namespace")
        canonical_segments = normalize_name(name)
        errors = []
        errors << "name must contain valid snake-case, kebab-case, or constant segments" unless canonical_segments
        errors << "namespace must be a bounded constant path" unless valid_namespace?(namespace)
        refuse!(operation, errors) if errors.any?

        @tool_name = canonical_segments.join(".")
        refuse!(operation, [ "normalized MCP tool name must be 1 to 64 characters" ]) unless
          @tool_name.length.between?(1, 64)

        nested_constants = canonical_segments.map(&:camelize)
        @class_name = ([ namespace ] + nested_constants).join("::")
        @test_class_name = "#{@class_name}Test"
        @class_modules = @class_name.split("::")[0...-1]
        @class_leaf = @class_name.split("::").last
        @tool_path = "app/tools/#{@class_name.underscore}.rb"
        @test_path = "test/integration/#{@class_name.underscore}_test.rb"
        @registration_line = %(register #{@class_name}, scopes: [ "mcp" ])
      end

      def normalize_name(value)
        return unless value.is_a?(String) && value.bytesize.between?(1, 256)

        source = value.gsub("::", "/")
        return if source.start_with?("/") || source.end_with?("/") || source.include?("//")

        segments = source.split("/")
        normalized = segments.filter_map do |segment|
          next unless NAME_SEGMENT_PATTERN.match?(segment)

          candidate = segment.match?(/\A[A-Z]/) ? segment.underscore : segment.tr("-", "_")
          candidate if CANONICAL_SEGMENT_PATTERN.match?(candidate)
        end
        normalized if normalized.length == segments.length
      end

      def valid_namespace?(value)
        return false unless value.is_a?(String) && value.bytesize.between?(1, 255)
        return false unless NAMESPACE_PATTERN.match?(value)

        segments = value.split("::")
        segments.length <= 8 && segments.all? { |segment| segment.bytesize <= 64 }
      end

      def deny_default?
        options.fetch("deny_default")
      end

      def operation
        behavior == :revoke ? "rollback" : "generation"
      end

      def refusal_subject = "Hitch tool"

      def print_next_steps
        say ""
        if deny_default?
          say "Generated and registered deny-default Hitch MCP tool #{@class_name}.", :green
          say "It stays unavailable until you implement it."
        else
          say "Generated and registered Hitch MCP tool #{@class_name}.", :green
          say "Verify it responds: bin/rails test #{@test_path}"
        end
      end
    end
  end
end
