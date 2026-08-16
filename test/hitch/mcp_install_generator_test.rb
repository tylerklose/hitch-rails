# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "rails/generators/test_case"
require "generators/hitch/mcp/install_generator"

class Hitch::MCPInstallGeneratorTest < Rails::Generators::TestCase
  tests Hitch::Generators::MCP::InstallGenerator
  destination File.expand_path("../../tmp/mcp_install_generator", __dir__)
  setup :prepare_destination

  SCENARIO_PATH = Rails.root.join("../lattice/mcp_install_generator_scenarios.json").expand_path
  SCENARIOS = JSON.parse(SCENARIO_PATH.read).fetch("scenarios").freeze
  CUSTOM_CONTROLLER = "Admin::McpController"
  GENERATED_STATIC_PATHS = %w[
    app/models/mcp_tool_registry.rb
    config/initializers/hitch_mcp.rb
    config/hitch_mcp_install.json
  ].freeze

  setup do
    prepare_auth_host
  end

  test "default install creates a deny-default host runtime before the engine mount" do
    output, error = invoke_generator

    assert_predicate self.class.generator_class, :exit_on_failure?
    assert_nil error
    assert_includes output, "without registering any tools"
    assert_file "app/controllers/mcp_controller.rb", /class McpController < ActionController::API/
    assert_file "app/controllers/mcp_controller.rb", /include Hitch::MCP::Endpoint/
    assert_file "app/models/mcp_tool_registry.rb", /class McpToolRegistry < Hitch::MCP::Registry/
    refute_match(/\bregister\b/, read("app/models/mcp_tool_registry.rb"))

    initializer = read("config/initializers/hitch_mcp.rb")
    assert_includes initializer, 'config.mcp.registry = "McpToolRegistry"'
    assert_includes initializer, "scope_resolver = ->(principal:, access_token:, request:) { nil }"
    assert_includes initializer, "# config.mcp.rate_limit_store ="
    refute_includes initializer, "rate_limit_redis_url"
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(initializer) }

    routes = read("config/routes.rb")
    assert_operator routes.index("# BEGIN hitch:mcp:install"), :<, routes.index("mount Hitch::Engine")
    assert_includes routes, 'match "/mcp", to: "mcp#handle", via: :all'
    assert_manifest("McpController", "app/controllers/mcp_controller.rb")
  end

  test "controller-name escape hatch creates the exact namespace path and route target" do
    output, error = invoke_generator(controller_name: "custom_valid")

    assert_nil error
    assert_includes output, "Hitch MCP runtime installed"
    assert_file "app/controllers/admin/mcp_controller.rb", /module Admin/
    assert_file "app/controllers/admin/mcp_controller.rb", /class McpController < ActionController::API/
    assert_includes read("config/routes.rb"), 'to: "admin/mcp#handle"'
    assert_manifest(CUSTOM_CONTROLLER, "app/controllers/admin/mcp_controller.rb")
  end

  test "pairwise prerequisite name and collision rows either install completely or write nothing" do
    assert_equal 25, SCENARIOS.length
    assert_equal (1..25).to_a, SCENARIOS.map { |scenario| scenario.fetch("id") }

    SCENARIOS.each do |scenario|
      prepare_destination
      prepare_auth_host
      values = scenario.fetch("values")
      apply_scenario_fixture(values)
      before = file_snapshot

      _output, error = invoke_generator(
        controller_name: values.fetch("controller_name"),
        migrations: values.fetch("prerequisite") != "missing_migrations",
        constant_collision: constant_collision_target(values)
      )

      if successful_scenario?(values)
        assert_nil error, scenario_label(scenario)
        assert destination_file?("config/hitch_mcp_install.json"), scenario_label(scenario)
        assert destination_file?(controller_path(values.fetch("controller_name"))), scenario_label(scenario)
      else
        assert_instance_of Thor::Error, error, scenario_label(scenario)
        assert_equal before, file_snapshot, scenario_label(scenario)
      end
    end
  end

  test "rerun refuses idempotently instead of overwriting the installed host" do
    _output, first_error = invoke_generator
    before = file_snapshot
    _output, second_error = invoke_generator

    assert_nil first_error
    assert_instance_of Thor::Error, second_error
    assert_includes second_error.message, "install refused"
    assert_equal before, file_snapshot
  end

  test "an earlier wildcard route refuses before writing an unreachable MCP endpoint" do
    routes_path = destination_path("config/routes.rb")
    File.write(
      routes_path,
      read("config/routes.rb").sub(
        "  mount Hitch::Engine",
        "  match \"*path\", to: \"host#dispatch\", via: :all\n  mount Hitch::Engine"
      )
    )
    before = file_snapshot

    _output, error = invoke_generator

    assert_instance_of Thor::Error, error
    assert_includes error.message, "wildcard route that may shadow /mcp"
    assert_equal before, file_snapshot
  end

  test "a slashless Rails MCP route refuses before writing a dual endpoint" do
    %(
      post "mcp", to: "legacy#dispatch"
      match "mcp", to: "legacy#dispatch", via: :all
    ).lines.map(&:strip).reject(&:empty?).each do |route|
      routes_path = destination_path("config/routes.rb")
      original = read("config/routes.rb")
      File.write(
        routes_path,
        original.sub("  mount Hitch::Engine", "  #{route}\n  mount Hitch::Engine")
      )
      before = file_snapshot

      _output, error = invoke_generator

      assert_instance_of Thor::Error, error
      assert_includes error.message, "already owns /mcp"
      assert_equal before, file_snapshot
      File.write(routes_path, original)
    end
  end

  test "a nested MCP route does not collide with the exact canonical endpoint" do
    routes_path = destination_path("config/routes.rb")
    File.write(
      routes_path,
      read("config/routes.rb").sub(
        "  mount Hitch::Engine",
        "  post \"mcp/diagnostics\", to: \"diagnostics#create\"\n  mount Hitch::Engine"
      )
    )

    _output, error = invoke_generator

    assert_nil error
    assert_includes read("config/routes.rb"), 'post "mcp/diagnostics"'
    assert_includes read("config/routes.rb"), 'match "/mcp"'
  end

  test "an earlier root mount refuses before writing an unreachable MCP endpoint" do
    routes_path = destination_path("config/routes.rb")
    File.write(
      routes_path,
      read("config/routes.rb").sub(
        "  mount Hitch::Engine",
        "  mount Legacy::Engine => \"/\"\n  mount Hitch::Engine"
      )
    )
    before = file_snapshot

    _output, error = invoke_generator

    assert_instance_of Thor::Error, error
    assert_includes error.message, "root mount that may shadow /mcp"
    assert_equal before, file_snapshot
  end

  test "rollback removes only exact generated bytes and preserves unrelated routes" do
    _output, install_error = invoke_generator
    routes_path = destination_path("config/routes.rb")
    File.write(routes_path, read("config/routes.rb").sub("end\n", "  get \"/health\", to: proc { [200, {}, []] }\nend\n"))

    _output, rollback_error = invoke_generator(behavior: :revoke)

    assert_nil install_error
    assert_nil rollback_error
    assert_no_file "app/controllers/mcp_controller.rb"
    GENERATED_STATIC_PATHS.each { |path| assert_no_file path }
    routes = read("config/routes.rb")
    assert_includes routes, 'get "/health"'
    assert_includes routes, "mount Hitch::Engine"
    refute_includes routes, "hitch:mcp:install"
    refute_includes routes, 'match "/mcp"'
  end

  test "rollback refuses every customized generated artifact before deleting anything" do
    customizations = {
      "controller" => -> { append("app/controllers/mcp_controller.rb", "# host edit\n") },
      "registry" => -> { append("app/models/mcp_tool_registry.rb", "# host edit\n") },
      "initializer" => -> { append("config/initializers/hitch_mcp.rb", "# host edit\n") },
      "route" => lambda {
        path = destination_path("config/routes.rb")
        File.write(path, read("config/routes.rb").sub('to: "mcp#handle"', 'to: "custom#handle"'))
      }
    }

    customizations.each do |label, customize|
      prepare_destination
      prepare_auth_host
      _output, install_error = invoke_generator
      customize.call
      before = file_snapshot

      _output, rollback_error = invoke_generator(behavior: :revoke)

      assert_nil install_error, label
      assert_instance_of Thor::Error, rollback_error, label
      assert_includes rollback_error.message, "rollback refused", label
      assert_equal before, file_snapshot, label
    end
  end

  test "missing engine mount and invalid rollback manifest refuse without mutation" do
    File.write(destination_path("config/routes.rb"), "Rails.application.routes.draw do\nend\n")
    before_install = file_snapshot
    _output, install_error = invoke_generator

    assert_instance_of Thor::Error, install_error
    assert_equal before_install, file_snapshot

    prepare_destination
    prepare_auth_host
    _output, successful_error = invoke_generator
    File.write(destination_path("config/hitch_mcp_install.json"), "{}\n")
    before_rollback = file_snapshot
    _output, rollback_error = invoke_generator(behavior: :revoke)

    assert_nil successful_error
    assert_instance_of Thor::Error, rollback_error
    assert_equal before_rollback, file_snapshot
  end

  test "rollback refuses internally inconsistent manifest paths and route blocks" do
    tamperings = {
      "controller path" => lambda do |manifest|
        manifest.fetch("files").first["path"] = "app/controllers/application_controller.rb"
      end,
      "controller name" => ->(manifest) { manifest["controller_name"] = "Admin::McpController" },
      "route block" => ->(manifest) { manifest.fetch("route")["block"] = "  mount Hitch::Engine, at: \"/\"\n" },
      "mount relationship" => ->(manifest) { manifest.fetch("route")["must_precede"] = "anything" },
      "rollback command" => ->(manifest) { manifest["rollback_command"] = "bin/rails destroy anything" }
    }

    tamperings.each do |label, tamper|
      prepare_destination
      prepare_auth_host
      _output, install_error = invoke_generator
      manifest_path = destination_path("config/hitch_mcp_install.json")
      manifest = JSON.parse(File.binread(manifest_path))
      tamper.call(manifest)
      File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
      before = file_snapshot

      _output, rollback_error = invoke_generator(behavior: :revoke)

      assert_nil install_error, label
      assert_instance_of Thor::Error, rollback_error, label
      assert_includes rollback_error.message, "rollback refused", label
      assert_equal before, file_snapshot, label
    end
  end

  private

  def prepare_auth_host
    mkdir_p(destination_path("config/initializers"))
    File.write(destination_path("config/initializers/hitch.rb"), "# installed auth substrate\n")
    File.write(
      destination_path("config/routes.rb"),
      "Rails.application.routes.draw do\n  mount Hitch::Engine, at: \"/\"\nend\n"
    )
  end

  def invoke_generator(controller_name: "default", migrations: true, constant_collision: nil, behavior: :invoke)
    arguments = controller_arguments(controller_name)
    invocation = -> { run_generator(arguments, { behavior:, debug: true }) }
    invocation = migration_wrapper(invocation) unless migrations
    invocation = constant_collision_wrapper(invocation, constant_collision) if constant_collision
    [ invocation.call, nil ]
  rescue Thor::Error => error
    [ nil, error ]
  end

  def migration_wrapper(invocation)
    connection = Object.new
    connection.define_singleton_method(:data_source_exists?) { |_table| false }
    -> do
      stub_class_method(ActiveRecord::Base, :connection, -> { connection }) { invocation.call }
    end
  end

  def constant_collision_wrapper(invocation, target)
    original_defined = Object.method(:const_defined?)
    original_source = Object.method(:const_source_location)
    fake_source = destination_path("config/initializers/collision.rb")
    defined = lambda do |name, inherit = true|
      name.to_s == target ? true : original_defined.call(name, inherit)
    end
    source = lambda do |name, inherit = true|
      name.to_s == target ? [ fake_source, 1 ] : original_source.call(name, inherit)
    end

    -> do
      stub_class_method(Object, :const_defined?, defined) do
        stub_class_method(Object, :const_source_location, source) { invocation.call }
      end
    end
  end

  def apply_scenario_fixture(values)
    File.delete(destination_path("config/initializers/hitch.rb")) if
      values.fetch("prerequisite") == "missing_auth_initializer"

    path = case values.fetch("collision")
    when "controller_file"
      controller_path(values.fetch("controller_name"))
    when "initializer_file"
      "config/initializers/hitch_mcp.rb"
    when "registry_file"
      "app/models/mcp_tool_registry.rb"
    when "manifest"
      "config/hitch_mcp_install.json"
    end
    if path
      mkdir_p(File.dirname(destination_path(path)))
      File.write(destination_path(path), "host-owned collision\n")
    end

    if values.fetch("collision") == "route"
      routes = read("config/routes.rb").sub(
        "  mount Hitch::Engine",
        "  match \"/mcp\", to: \"existing#handle\", via: :all\n  mount Hitch::Engine"
      )
      File.write(destination_path("config/routes.rb"), routes)
    end
  end

  def constant_collision_target(values)
    case values.fetch("collision")
    when "controller_constant"
      values.fetch("controller_name") == "custom_valid" ? CUSTOM_CONTROLLER : "McpController"
    when "registry_constant"
      "McpToolRegistry"
    end
  end

  def successful_scenario?(values)
    values.fetch("prerequisite") == "complete" &&
      values.fetch("controller_name") != "invalid" &&
      values.fetch("collision") == "none"
  end

  def controller_arguments(mode)
    case mode
    when "default" then []
    when "custom_valid" then [ "--controller-name", CUSTOM_CONTROLLER ]
    when "invalid" then [ "--controller-name", "not/a/constant" ]
    else raise "unknown controller mode: #{mode}"
    end
  end

  def controller_path(mode)
    mode == "custom_valid" ? "app/controllers/admin/mcp_controller.rb" : "app/controllers/mcp_controller.rb"
  end

  def assert_manifest(controller_name, controller_path)
    manifest = JSON.parse(read("config/hitch_mcp_install.json"))
    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "hitch:mcp:install", manifest.fetch("generator")
    assert_equal controller_name, manifest.fetch("controller_name")
    assert_equal [
      controller_path,
      "app/models/mcp_tool_registry.rb",
      "config/initializers/hitch_mcp.rb"
    ], manifest.fetch("files").map { |file| file.fetch("path") }
    manifest.fetch("files").each do |file|
      assert_equal Digest::SHA256.file(destination_path(file.fetch("path"))).hexdigest, file.fetch("sha256")
    end
    assert_equal "bin/rails destroy hitch:mcp:install", manifest.fetch("rollback_command")
  end

  def destination_file?(relative_path)
    File.file?(destination_path(relative_path))
  end

  def destination_path(relative_path)
    File.expand_path(relative_path, destination_root)
  end

  def read(relative_path)
    File.binread(destination_path(relative_path))
  end

  def append(relative_path, content)
    File.open(destination_path(relative_path), "ab") { |file| file.write(content) }
  end

  def file_snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: destination_root).sort.filter_map do |relative_path|
      absolute_path = destination_path(relative_path)
      [ relative_path, File.binread(absolute_path) ] if File.file?(absolute_path)
    end.to_h
  end

  def scenario_label(scenario)
    "scenario #{scenario.fetch('id')}: #{scenario.fetch('values')}"
  end
end
