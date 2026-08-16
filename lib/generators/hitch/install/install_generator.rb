# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "rails/generators"
require_relative "../generator_guards"

module Hitch
  module Generators
    # One install: the initializer, the /mcp endpoint controller, an empty
    # explicit tool registry, and the routes, in order. Migrations are
    # auto-appended by the engine; run db:migrate after install.
    #
    # Usage:
    #   bin/rails generate hitch:install
    #   bin/rails destroy hitch:install
    class InstallGenerator < ::Rails::Generators::Base
      include Hitch::Generators::GeneratorGuards

      # Declared explicitly so the command is always `hitch:install`,
      # independent of generator-discovery ordering.
      namespace "hitch:install"

      source_root File.expand_path("templates", __dir__)

      class_option :controller_name,
        type: :string,
        default: "McpController",
        desc: "Host controller constant to create (must end in Controller)"

      INITIALIZER_PATH = "config/initializers/hitch.rb"
      ROUTES_PATH = "config/routes.rb"
      CONTROLLER_PATTERN = /\A[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*Controller\z/
      MCP_ROUTE_PATTERN = /["']\/?mcp\/?["']/

      def self.exit_on_failure?
        true
      end

      def install_or_revoke
        prepare_identity!

        if behavior == :revoke
          remove_files
          remove_routes
        else
          preflight!
          create_files
          add_routes
          print_next_steps
        end
      end

      private

      def prepare_identity!
        controller_name = options.fetch("controller_name")
        unless CONTROLLER_PATTERN.match?(controller_name)
          refuse!(operation, [ "controller name must be a constant path ending in Controller" ])
        end

        @controller_name = controller_name
        @controller_modules = controller_name.split("::")[0...-1]
        @controller_leaf = controller_name.split("::").last
        @controller_path = "app/controllers/#{controller_name.underscore}.rb"
        @route_target = controller_name.delete_suffix("Controller").underscore
      end

      def preflight!
        errors = []
        [ INITIALIZER_PATH, @controller_path, REGISTRY_PATH ].each do |path|
          errors << "file collision: #{path}" if destination_file?(path)
        end
        errors << "constant collision: #{@controller_name}" if constant_collision?(@controller_name)
        errors << "constant collision: McpToolRegistry" if constant_collision?("McpToolRegistry")
        errors << "#{ROUTES_PATH} is missing a Rails.application.routes.draw block" unless
          active_routes.include?(".routes.draw do")
        refuse!("install", errors) if errors.any?
      end

      # Behavior-aware Thor actions: create in invoke, remove in revoke.
      def create_files
        template "initializer.rb", INITIALIZER_PATH
        template "controller.rb.tt", @controller_path
        template "registry.rb", REGISTRY_PATH
      end
      alias_method :remove_files, :create_files

      # The /mcp route must precede the engine mount, so both go into one
      # insertion at the top of the draw block.
      def add_routes
        active = active_routes
        match_missing = !MCP_ROUTE_PATTERN.match?(active)
        mount_missing = !active.include?("mount Hitch::Engine")

        say_status :warn, "#{ROUTES_PATH} already routes /mcp; leaving it as is", :yellow unless match_missing
        say_status :skip, "Hitch::Engine is already mounted", :yellow unless mount_missing
        return unless match_missing || mount_missing

        route(
          [
            (match_line if match_missing),
            (mount_line if mount_missing)
          ].compact.join("\n")
        )
      end

      # Removes only the line this generator always writes. With no install
      # record there is no way to tell a generated engine mount from one the
      # host already had, and deleting a host-owned mount would take down its
      # /oauth/* and discovery routes — so the mount is left in place and
      # said so.
      def remove_routes
        active = active_routes
        route(match_line) if active.include?(match_line)
        return unless active.include?("mount Hitch::Engine")

        say_status :skip,
          "mount Hitch::Engine left in place (it may pre-date this install); remove it manually if unwanted",
          :yellow
      end

      def match_line
        %(match "/mcp", to: "#{@route_target}#handle", via: :all)
      end

      def mount_line
        'mount Hitch::Engine => "/"'
      end

      def active_routes
        return "" unless destination_file?(ROUTES_PATH)

        File.binread(destination_path(ROUTES_PATH))
          .each_line.reject { |line| line.lstrip.start_with?("#") }.join
      end

      def operation
        behavior == :revoke ? "removal" : "install"
      end

      def refusal_subject = "Hitch"

      def print_next_steps
        say ""
        say "hitch-rails installed.", :green
        say "Next steps:"
        say "  1. Set resource_uri and brand_name in #{INITIALIZER_PATH}"
        say "  2. Run: bin/rails db:migrate"
        say "  3. Generate your first tool: bin/rails generate hitch:tool echo"
      end
    end
  end
end
