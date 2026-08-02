# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "digest"
require "json"
require "rails/generators"

module Hitch
  module Generators
    module MCP
      class InstallGenerator < ::Rails::Generators::Base
        namespace "hitch:mcp:install"

        source_root File.expand_path("templates", __dir__)

        def self.exit_on_failure?
          true
        end

        class_option :controller_name,
          type: :string,
          default: "McpController",
          desc: "Host controller constant to create (must end in Controller)"

        AUTH_INITIALIZER_PATH = "config/initializers/hitch.rb"
        MCP_INITIALIZER_PATH = "config/initializers/hitch_mcp.rb"
        REGISTRY_PATH = "app/models/mcp_tool_registry.rb"
        ROUTES_PATH = "config/routes.rb"
        MANIFEST_PATH = "config/hitch_mcp_install.json"
        REQUIRED_AUTH_TABLES = %w[
          hitch_access_tokens
          hitch_clients
          hitch_client_redirect_uris
          hitch_schema_states
        ].freeze
        CONTROLLER_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*Controller\z/
        ENGINE_MOUNT_PATTERN = /^([ \t]*)mount[ \t]+Hitch::Engine\b.*$/
        MCP_ROUTE_PATTERN = /["']\/mcp(?:[\/"']|\z)/
        ROUTE_BEGIN = "# BEGIN hitch:mcp:install"
        ROUTE_END = "# END hitch:mcp:install"

        def install_or_rollback
          behavior == :revoke ? rollback! : install!
        end

        private

        def install!
          prepare_install!

          template "controller.rb.tt", @controller_path
          template "registry.rb.tt", REGISTRY_PATH
          template "initializer.rb.tt", MCP_INITIALIZER_PATH
          insert_into_file ROUTES_PATH, @route_block, before: @engine_mount
          create_file MANIFEST_PATH, "#{JSON.pretty_generate(install_manifest)}\n"

          say ""
          say "Hitch MCP runtime installed without registering any tools.", :green
          say "Generated rollback manifest: #{MANIFEST_PATH}"
          say "Next: add a Hitch::MCP::Tool, then register it explicitly."
        end

        def prepare_install!
          errors = []
          controller_name = options.fetch("controller_name")
          errors << "controller name must be a constant path ending in Controller" unless
            CONTROLLER_PATTERN.match?(controller_name)

          routes = read_file(ROUTES_PATH)
          errors << "#{AUTH_INITIALIZER_PATH} is missing; run hitch:install first" unless
            destination_file?(AUTH_INITIALIZER_PATH)
          errors << "Hitch auth migrations are missing; run bin/rails db:migrate first" unless
            auth_migrations_installed?

          mount_matches = routes&.scan(ENGINE_MOUNT_PATTERN) || []
          errors << "#{ROUTES_PATH} must contain exactly one Hitch::Engine mount" unless mount_matches.length == 1
          errors << "#{ROUTES_PATH} already owns /mcp or contains a Hitch MCP install marker" if
            routes && route_collision?(routes)

          controller_path = controller_path_for(controller_name) if CONTROLLER_PATTERN.match?(controller_name)
          collision_paths = [ controller_path, MCP_INITIALIZER_PATH, REGISTRY_PATH, MANIFEST_PATH ].compact
          collision_paths.each do |path|
            errors << "file collision: #{path}" if destination_file?(path)
          end
          if CONTROLLER_PATTERN.match?(controller_name) && constant_collision?(controller_name)
            errors << "constant collision: #{controller_name}"
          end
          errors << "constant collision: McpToolRegistry" if constant_collision?("McpToolRegistry")

          refuse!("install", errors) if errors.any?

          @controller_name = controller_name
          @controller_path = controller_path
          @controller_modules = controller_name.split("::")[0...-1]
          @controller_leaf = controller_name.split("::").last
          @route_target = controller_name.delete_suffix("Controller").underscore
          @engine_mount = routes.match(ENGINE_MOUNT_PATTERN)[0]
          indentation = routes.match(ENGINE_MOUNT_PATTERN)[1]
          @route_block = route_block_for(controller_name, indentation)
        end

        def rollback!
          manifest = load_manifest
          errors = validate_manifest(manifest)
          refuse!("rollback", errors) if errors.any?

          routes_path = destination_path(ROUTES_PATH)
          route_block = manifest.dig("route", "block")
          routes = File.binread(routes_path)
          File.binwrite(routes_path, routes.sub(route_block, ""))
          manifest.fetch("files").reverse_each do |file|
            File.delete(destination_path(file.fetch("path")))
          end
          File.delete(destination_path(MANIFEST_PATH))

          say "Hitch MCP generated files and exact route block removed.", :green
        end

        def install_manifest
          {
            "schema_version" => 1,
            "generator" => "hitch:mcp:install",
            "controller_name" => @controller_name,
            "files" => [ @controller_path, REGISTRY_PATH, MCP_INITIALIZER_PATH ].map do |path|
              { "path" => path, "sha256" => sha256(path) }
            end,
            "route" => {
              "path" => ROUTES_PATH,
              "block" => @route_block,
              "must_precede" => "mount Hitch::Engine"
            },
            "rollback_command" => "bin/rails destroy hitch:mcp:install"
          }
        end

        def load_manifest
          JSON.parse(File.binread(destination_path(MANIFEST_PATH)))
        rescue Errno::ENOENT
          refuse!("rollback", [ "missing rollback manifest: #{MANIFEST_PATH}" ])
        rescue JSON::ParserError
          refuse!("rollback", [ "rollback manifest is invalid JSON: #{MANIFEST_PATH}" ])
        end

        def validate_manifest(manifest)
          errors = []
          unless manifest.is_a?(Hash) && manifest["schema_version"] == 1 &&
              manifest["generator"] == "hitch:mcp:install" &&
              manifest["controller_name"].is_a?(String) &&
              CONTROLLER_PATTERN.match?(manifest["controller_name"]) &&
              manifest["rollback_command"] == "bin/rails destroy hitch:mcp:install"
            return [ "rollback manifest contract is invalid" ]
          end

          controller_name = manifest.fetch("controller_name")
          expected_paths = [
            controller_path_for(controller_name),
            REGISTRY_PATH,
            MCP_INITIALIZER_PATH
          ]
          files = manifest["files"]
          unless valid_manifest_files?(files, expected_paths)
            errors << "rollback manifest file set is invalid"
            return errors
          end

          files.each do |file|
            path = file.fetch("path")
            unless destination_file?(path)
              errors << "generated file is missing: #{path}"
              next
            end
            errors << "generated file was customized: #{path}" unless sha256(path) == file.fetch("sha256")
          end

          route = manifest["route"]
          unless valid_manifest_route?(route, controller_name)
            errors << "rollback route contract is invalid"
            return errors
          end
          routes = read_file(ROUTES_PATH)
          errors << "generated route block was customized or removed" unless
            routes && routes.scan(Regexp.new(Regexp.escape(route.fetch("block")))).length == 1

          errors
        end

        def valid_manifest_files?(files, expected_paths)
          return false unless files.is_a?(Array) && files.length == 3

          paths = files.filter_map do |file|
            next unless file.is_a?(Hash) && file["path"].is_a?(String) &&
              file["sha256"].is_a?(String) && file["sha256"].match?(/\A[0-9a-f]{64}\z/)

            file["path"]
          end
          paths == expected_paths
        end

        def valid_manifest_route?(route, controller_name)
          return false unless route.is_a?(Hash) && route["path"] == ROUTES_PATH &&
            route["block"].is_a?(String) && route["must_precede"] == "mount Hitch::Engine"

          indentation = route.fetch("block")[/\A([ \t]*)#{Regexp.escape(ROUTE_BEGIN)}\n/, 1]
          indentation && route.fetch("block") == route_block_for(controller_name, indentation)
        end

        def route_block_for(controller_name, indentation)
          route_target = controller_name.delete_suffix("Controller").underscore
          [
            "#{indentation}#{ROUTE_BEGIN}",
            %(#{indentation}match "/mcp", to: "#{route_target}#handle", via: :all),
            "#{indentation}#{ROUTE_END}",
            ""
          ].join("\n")
        end

        def route_collision?(routes)
          active_lines = routes.each_line.reject { |line| line.lstrip.start_with?("#") }.join
          routes.include?(ROUTE_BEGIN) || routes.include?(ROUTE_END) || MCP_ROUTE_PATTERN.match?(active_lines)
        end

        def controller_path_for(controller_name)
          "app/controllers/#{controller_name.underscore}.rb"
        end

        def constant_collision?(name)
          return false unless Object.const_defined?(name, false)
          return true if File.expand_path(destination_root) == File.expand_path(Rails.root)

          source = Object.const_source_location(name, false)&.first
          source && File.expand_path(source).start_with?("#{File.expand_path(destination_root)}/")
        rescue NameError
          false
        end

        def auth_migrations_installed?
          return false unless defined?(ActiveRecord::Base)

          connection = ActiveRecord::Base.connection
          REQUIRED_AUTH_TABLES.all? { |table| connection.data_source_exists?(table) }
        rescue ActiveRecord::ActiveRecordError, NoMethodError
          false
        end

        def destination_file?(relative_path)
          File.file?(destination_path(relative_path))
        end

        def destination_path(relative_path)
          File.expand_path(relative_path, destination_root)
        end

        def read_file(relative_path)
          File.binread(destination_path(relative_path))
        rescue Errno::ENOENT
          nil
        end

        def sha256(relative_path)
          Digest::SHA256.file(destination_path(relative_path)).hexdigest
        end

        def refuse!(operation, errors)
          raise ::Thor::Error, "Hitch MCP #{operation} refused:\n- #{errors.join("\n- ")}"
        end
      end
    end
  end
end
