# frozen_string_literal: true

require "test_helper"
require "open3"
require "timeout"

class Hitch::RegistryLifecycleBootTest < ActiveSupport::TestCase
  HOST_SCRIPT = <<~'RUBY'
    require "bundler/setup"
    require "fileutils"
    require "logger"
    require "tmpdir"
    require "active_record/railtie"
    require "action_controller/railtie"

    def write_tool(path, description, eager_reload: false)
      File.write(path, <<~TOOL)
        class HostLifecycleTool < Hitch::MCP::Tool
          MODEL_TRANSLATION = ActiveModel::Translation
          RECORD_BASE = ActiveRecord::Base
          raise "tool loaded before Rails eager reload" if #{eager_reload.inspect} &&
            !Rails.autoloaders.main.instance_variable_get(:@host_lifecycle_eager_reload)

          tool_name "host.lifecycle"
          description #{description.dump}
          input_schema(type: "object", properties: {}, additionalProperties: false)
          annotations read_only_hint: true,
            destructive_hint: false,
            idempotent_hint: true,
            open_world_hint: false
        end
      TOOL
    end

    Dir.mktmpdir("hitch-registry-lifecycle-host") do |root|
      FileUtils.mkdir_p(File.join(root, "config"))
      FileUtils.mkdir_p(File.join(root, "app/controllers"))
      FileUtils.mkdir_p(File.join(root, "app/tools"))
      File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw {}\n")
      adapter = Gem::Specification.find_all_by_name("sqlite3").any? ? "sqlite3" : "postgresql"
      database = adapter == "sqlite3" ? ":memory:" : "hitch_registry_lifecycle"
      File.write(File.join(root, "config/database.yml"), <<~YAML)
        test:
          adapter: #{adapter}
          database: #{database.dump}
      YAML
      File.write(File.join(root, "app/controllers/application_controller.rb"), <<~'CONTROLLER')
        class ApplicationController < ActionController::Base
        end
      CONTROLLER

      mode = ENV.fetch("HITCH_REGISTRY_LIFECYCLE_MODE")
      tool_path = File.join(root, "app/tools/host_lifecycle_tool.rb")
      write_tool(tool_path, "version one") unless mode == "invalid"

      registry_name = case mode
      when "non_eager", "eager_reload", "invalid_server_info"
        File.write(File.join(root, "app/tools/host_lifecycle_registry.rb"), <<~'REGISTRY')
          class HostLifecycleRegistry < Hitch::MCP::Registry
            register HostLifecycleTool, scopes: [ "mcp" ]
          end
        REGISTRY
        "HostLifecycleRegistry"
      when "invalid"
        Object.const_set(:InvalidHostLifecycleRegistry, Class.new)
        "InvalidHostLifecycleRegistry"
      else
        raise "unknown lifecycle mode"
      end

      class RegistryLifecycleHost < Rails::Application
        config.eager_load = ENV.fetch("HITCH_REGISTRY_LIFECYCLE_EAGER") == "1"
        config.enable_reloading = ENV.fetch("HITCH_REGISTRY_LIFECYCLE_RELOAD") == "1"
        config.reload_classes_only_on_change =
          ENV.fetch("HITCH_REGISTRY_LIFECYCLE_ON_CHANGE", "1") == "1"
        config.file_watcher = ActiveSupport::FileUpdateChecker
        config.logger = Logger.new(IO::NULL)
        config.cache_store = :memory_store
        config.hosts.clear
        config.secret_key_base = "x" * 64
        if config.respond_to?(:action_on_early_load_hook=)
          config.action_on_early_load_hook = :raise
        end
      end

      RegistryLifecycleHost.config.root = root
      require "hitch"
      Hitch.configure do |configuration|
        configuration.resource_uri = "https://lifecycle.test/mcp"
        configuration.dynamic_client_registration_enabled = false
        configuration.mcp.enabled = true
        configuration.mcp.registry = registry_name
        configuration.mcp.server_info = if mode == "invalid_server_info"
          { name: "lifecycle-host" }
        else
          { name: "lifecycle-host", version: "1" }
        end
      end

      RegistryLifecycleHost.initialize!

      case mode
      when "non_eager"
        unless Object.autoload?(:HostLifecycleRegistry) && Object.autoload?(:HostLifecycleTool)
          raise "non-eager boot loaded the host registry or tool"
        end

        snapshot = Hitch.configuration.mcp.ensure_registry_prepared!(
          supported_scopes: Hitch.configuration.supported_scopes
        )
        unless snapshot.registry_name == "HostLifecycleRegistry" &&
            snapshot.entries.map(&:name) == [ "host.lifecycle" ]
          raise "first MCP use did not prepare the registry"
        end
        first_tool = HostLifecycleTool
        write_tool(tool_path, "non-eager version two")
        Rails.application.reloader.reload!
        begin
          Hitch.configuration.mcp.registry_snapshot!
          raise "non-eager reload retained the old registry snapshot"
        rescue ArgumentError => error
          raise unless error.message == "MCP registry is unavailable"
        end

        second_snapshot = Hitch.configuration.mcp.ensure_registry_prepared!(
          supported_scopes: Hitch.configuration.supported_scopes
        )
        if HostLifecycleTool.equal?(first_tool) ||
            second_snapshot.equal?(snapshot) ||
            second_snapshot.entries.map(&:description) != [ "non-eager version two" ]
          raise "first MCP use after reload did not prepare the new registry"
        end
        puts "NON_EAGER_REGISTRY_RELOADED"
      when "eager_reload"
        first_tool = HostLifecycleTool
        first_snapshot = Hitch.configuration.mcp.registry_snapshot!
        unless first_snapshot.entries.map(&:description) == [ "version one" ]
          raise "eager boot did not prepare the registry"
        end

        main_loader = Rails.autoloaders.main
        main_loader.instance_variable_set(:@host_lifecycle_eager_reload, false)
        class << main_loader
          alias_method :host_lifecycle_original_eager_load, :eager_load

          def eager_load(...)
            @host_lifecycle_eager_reload = true
            host_lifecycle_original_eager_load(...)
          end
        end
        write_tool(tool_path, "version two", eager_reload: true)
        Rails.application.reloader.reload!

        second_snapshot = Hitch.configuration.mcp.registry_snapshot!
        if HostLifecycleTool.equal?(first_tool) ||
            second_snapshot.equal?(first_snapshot) ||
            second_snapshot.entries.map(&:description) != [ "version two" ]
          raise "reload did not replace the registry snapshot after Rails reloaded the tool"
        end
        puts "EAGER_REGISTRY_RELOADED"
      end
    end
  RUBY

  test "non-eager boot and reload defer a framework-touching registry until MCP use" do
    stdout, stderr, status = boot(mode: "non_eager", eager: false, reload: true)

    assert_predicate status, :success?, "non-eager host boot failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "NON_EAGER_REGISTRY_RELOADED"
  end

  test "eager reload rebuilds after Rails unloads classes in on-change mode" do
    assert_eager_reload(on_change: true)
  end

  test "eager reload rebuilds after Rails unloads classes after each request" do
    assert_eager_reload(on_change: false)
  end

  test "eager boot refuses a configured constant that is not a registry" do
    stdout, stderr, status = boot(mode: "invalid", eager: true)

    refute_predicate status, :success?, "invalid registry booted:\n#{stdout}\n#{stderr}"
    assert_includes "#{stdout}\n#{stderr}", "mcp.registry must resolve to a Hitch::MCP::Registry subclass"
  end

  test "eager boot refuses malformed server info" do
    stdout, stderr, status = boot(mode: "invalid_server_info", eager: true)

    refute_predicate status, :success?, "malformed server info booted:\n#{stdout}\n#{stderr}"
    assert_includes "#{stdout}\n#{stderr}", "mcp.server_info"
  end

  private

  def assert_eager_reload(on_change:)
    stdout, stderr, status = boot(
      mode: "eager_reload",
      eager: true,
      reload: true,
      on_change:
    )

    assert_predicate status, :success?, "eager host reload failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "EAGER_REGISTRY_RELOADED"
  end

  def boot(mode:, eager:, reload: false, on_change: true)
    Timeout.timeout(30) do
      Open3.capture3(
        {
          "RAILS_ENV" => "test",
          "HITCH_REGISTRY_LIFECYCLE_MODE" => mode,
          "HITCH_REGISTRY_LIFECYCLE_EAGER" => eager ? "1" : "0",
          "HITCH_REGISTRY_LIFECYCLE_RELOAD" => reload ? "1" : "0",
          "HITCH_REGISTRY_LIFECYCLE_ON_CHANGE" => on_change ? "1" : "0"
        },
        RbConfig.ruby, "-Ilib", "-e", HOST_SCRIPT,
        chdir: repository_root
      )
    end
  end

  def repository_root
    Rails.root.join("../..").expand_path.to_s
  end
end
