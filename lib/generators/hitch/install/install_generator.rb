# frozen_string_literal: true

require "rails/generators"

module Hitch
  module Generators
    # Install generator: drops an initializer + mounts the engine in host
    # routes. Migrations are auto-appended by the engine; run db:migrate
    # after install. Idempotent — running twice is safe.
    #
    # Usage:
    #   bin/rails generate hitch:install
    class InstallGenerator < ::Rails::Generators::Base
      # Declared explicitly so the command is always `hitch:install`,
      # independent of generator-discovery ordering.
      namespace "hitch:install"

      source_root File.expand_path("templates", __dir__)

      def create_initializer
        template "initializer.rb", "config/initializers/hitch.rb"
      end

      def append_engine_mount
        routes_path = "config/routes.rb"
        if File.exist?(routes_path) && File.read(routes_path).include?("mount Hitch::Engine")
          say_status :skip, "Hitch::Engine mount already present in routes.rb", :yellow
          return
        end

        route 'mount Hitch::Engine, at: "/"'
      end

      def print_post_install
        say ""
        say "hitch-rails installed.", :green
        say "Next steps:"
        say "  1. Edit config/initializers/hitch.rb to set resource_uri + principal_model"
        say "  2. Run: bin/rails db:migrate"
        say "  3. The engine mount exposes /oauth/authorize, /oauth/token, /oauth/register,"
        say "     /oauth/revoke, /.well-known/oauth-authorization-server, and"
        say "     /.well-known/oauth-protected-resource"
      end
    end
  end
end
