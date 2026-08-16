# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "digest"
require "json"
require "rails/generators"
require_relative "manifested_generator"

module Hitch
  module Generators
    class ToolGenerator < ::Rails::Generators::Base
      include Hitch::Generators::ManifestedGenerator

      namespace "hitch:tool"

      source_root File.expand_path("tool/templates", __dir__)

      argument :name, type: :string, required: true,
        desc: "Tool name, optionally nested with / or ::"
      class_option :namespace,
        type: :string,
        default: "McpTools",
        desc: "Root Ruby namespace for the generated tool"

      NAME_SEGMENT_PATTERN =
        /\A(?:[a-z][a-z0-9]*(?:[_-][a-z0-9]+)*|[A-Z][A-Za-z0-9]*)\z/
      CANONICAL_SEGMENT_PATTERN = /\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
      NAMESPACE_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z/
      MANIFEST_DIRECTORY = "config/hitch_tools"
      DEFAULT_REGISTRY_PATH = "app/models/mcp_tool_registry.rb"

      def self.exit_on_failure?
        true
      end

      def generate_or_rollback
        prepare_identity!
        behavior == :revoke ? rollback! : generate!
      end

      private

      def generate!
        errors = []
        [ @tool_path, @test_path, @manifest_path ].each do |path|
          errors << "file collision: #{path}" if destination_file?(path)
        end
        errors << "constant collision: #{@class_name}" if constant_collision?(@class_name)
        errors << "constant collision: #{@test_class_name}" if constant_collision?(@test_class_name)
        refuse!("generation", errors) if errors.any?

        template "tool.rb.tt", @tool_path
        template "tool_test.rb.tt", @test_path
        create_file @manifest_path, "#{JSON.pretty_generate(generation_manifest)}\n"

        say ""
        say "Generated deny-default Hitch MCP tool #{@class_name}.", :green
        say "Registry unchanged. Review the tool, then add this line manually:"
        say "  #{@registration_line}"
        say "Rollback manifest: #{@manifest_path}"
      end

      def rollback!
        manifest = load_manifest
        errors = validate_manifest(manifest)
        if default_registry_contains_instruction?
          errors << "#{DEFAULT_REGISTRY_PATH} still contains the manual registration line; remove it first"
        end
        refuse!("rollback", errors) if errors.any?

        manifest.fetch("files").reverse_each do |file|
          File.delete(destination_path(file.fetch("path")))
        end
        File.delete(destination_path(@manifest_path))

        say "Removed exact generated tool and test bytes.", :green
        say "Registry was never edited. If added, remove this line manually:"
        say "  #{@registration_line}"
      end

      def prepare_identity!
        operation = behavior == :revoke ? "rollback" : "generation"
        namespace = options.fetch("namespace")
        canonical_segments = normalize_name(name)
        errors = []
        errors << "name must contain valid snake-case, kebab-case, or constant segments" unless canonical_segments
        errors << "namespace must be a bounded constant path" unless valid_namespace?(namespace)
        refuse!(operation, errors) if errors.any?

        @canonical_name = canonical_segments.join("/")
        @tool_name = canonical_segments.join(".")
        refuse!(operation, [ "normalized MCP tool name must be 1 to 64 characters" ]) unless
          @tool_name.length.between?(1, 64)

        @namespace = namespace
        nested_constants = canonical_segments.map(&:camelize)
        @class_name = ([ namespace ] + nested_constants).join("::")
        @test_class_name = "#{@class_name}Test"
        @class_modules = @class_name.split("::")[0...-1]
        @class_leaf = @class_name.split("::").last
        @tool_path = "app/models/#{@class_name.underscore}.rb"
        @test_path = "test/integration/#{@class_name.underscore}_test.rb"
        @manifest_path = "#{MANIFEST_DIRECTORY}/#{@tool_name}.json"
        @registration_line = %(register #{@class_name}, scopes: [ "mcp" ])
        @rollback_command = [
          "bin/rails destroy hitch:tool",
          @canonical_name,
          ("--namespace #{@namespace}" unless @namespace == "McpTools")
        ].compact.join(" ")
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

      def generation_manifest
        {
          "schema_version" => 1,
          "generator" => "hitch:tool",
          "canonical_name" => @canonical_name,
          "namespace" => @namespace,
          "class_name" => @class_name,
          "tool_name" => @tool_name,
          "files" => [ @tool_path, @test_path ].map do |path|
            { "path" => path, "sha256" => sha256(path) }
          end,
          "registry_instruction" => @registration_line,
          "rollback_command" => @rollback_command
        }
      end

      def refusal_subject = "Hitch tool"
      def manifest_path = @manifest_path

      def validate_manifest(manifest)
        return [ "rollback manifest contract is invalid" ] unless
          manifest.is_a?(Hash) &&
            manifest["schema_version"] == 1 &&
            manifest["generator"] == "hitch:tool" &&
            manifest["canonical_name"] == @canonical_name &&
            manifest["namespace"] == @namespace &&
            manifest["class_name"] == @class_name &&
            manifest["tool_name"] == @tool_name &&
            manifest["registry_instruction"] == @registration_line &&
            manifest["rollback_command"] == @rollback_command

        files = manifest["files"]
        expected_paths = [ @tool_path, @test_path ]
        return [ "rollback manifest file set is invalid" ] unless
          files.is_a?(Array) &&
            files.length == expected_paths.length &&
            files.map { |file| valid_manifest_file(file) }.all? &&
            files.map { |file| file.fetch("path") } == expected_paths

        files.filter_map do |file|
          path = file.fetch("path")
          if !destination_file?(path)
            "generated file is missing: #{path}"
          elsif sha256(path) != file.fetch("sha256")
            "generated file was customized: #{path}"
          end
        end
      end

      def valid_manifest_file(file)
        file.is_a?(Hash) &&
          file["path"].is_a?(String) &&
          file["sha256"].is_a?(String) &&
          file["sha256"].match?(/\A[0-9a-f]{64}\z/)
      end

      def default_registry_contains_instruction?
        path = destination_path(DEFAULT_REGISTRY_PATH)
        return false unless File.file?(path)

        File.binread(path).each_line.any? { |line| line.strip == @registration_line }
      end
    end
  end
end
