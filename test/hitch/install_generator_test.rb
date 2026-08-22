# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/hitch/install/install_generator"

# Runs the generator into a temporary destination and inspects what it
# emitted, rather than reading the templates. Reading a template proves the
# file on disk says the right thing; it proves nothing about whether the
# generator still copies it, or copies that one.
class Hitch::InstallGeneratorTest < Rails::Generators::TestCase
  tests Hitch::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator-#{Process.pid}", __dir__)
  setup :prepare_destination

  ROUTES = "Rails.application.routes.draw do\nend\n"

  setup do
    mkdir_p("#{destination_root}/config")
    File.write("#{destination_root}/config/routes.rb", ROUTES)
  end

  test "one install writes the initializer controller registry and ordered routes" do
    invoke_generator!

    assert_file "config/initializers/hitch.rb", /Hitch\.configure do \|config\|/
    assert_file "app/controllers/mcp_controller.rb", /class McpController < ActionController::API/
    assert_file "app/controllers/mcp_controller.rb", /include Hitch::MCP::Endpoint/
    assert_file "app/tools/mcp_tool_registry.rb", /class McpToolRegistry < Hitch::MCP::Registry/
    refute_match(/\bregister\b/, read("app/tools/mcp_tool_registry.rb"))

    routes = read("config/routes.rb")
    assert_includes routes, 'match "/mcp", to: "mcp#handle", via: :all'
    assert_includes routes, 'mount Hitch::Engine => "/"'
    assert_operator routes.index('match "/mcp"'), :<, routes.index("mount Hitch::Engine"),
      "the /mcp route must precede the engine mount"
  end

  test "the generated initializer enables the runtime and opts new installations into CIMD" do
    invoke_generator!
    initializer = generated_initializer

    assert_match(/^\s*config\.mcp\.enabled = true$/, initializer)
    assert_match(/^\s*config\.mcp\.registry = "McpToolRegistry"$/, initializer)
    assert_match(/^\s*config\.client_id_metadata_enabled = true$/, initializer,
                 "new installs are how CIMD reaches the spec's SHOULD, since the library fallback stays false")
    assert_match(/http_proxy/, initializer,
                 "a host behind a proxy would advertise support it cannot deliver — say so where it is configured")
    assert_match(/hitch:cimd:check/, initializer)
  end

  test "the generated initializer denies origins and DCR until the host opts in" do
    invoke_generator!
    initializer = generated_initializer

    assert_match(/^\s*config\.allowed_origins = \[\]$/, initializer)
    assert_match(/^\s*config\.dynamic_client_registration_enabled = false$/, initializer)
  end

  test "what it emits is valid Ruby that configures Hitch" do
    invoke_generator!

    [
      "config/initializers/hitch.rb",
      "app/controllers/mcp_controller.rb",
      "app/tools/mcp_tool_registry.rb"
    ].each do |path|
      assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(read(path)) }
    end
  end

  test "a custom controller name shapes the path class and route target" do
    invoke_generator!([ "--controller-name", "Admin::McpController" ])

    assert_file "app/controllers/admin/mcp_controller.rb", /module Admin/
    assert_file "app/controllers/admin/mcp_controller.rb", /class McpController < ActionController::API/
    assert_includes read("config/routes.rb"), 'to: "admin/mcp#handle"'
  end

  test "an invalid controller name refuses before writing anything" do
    error = assert_raises(Thor::Error) { invoke_generator!([ "--controller-name", "not/a/constant" ]) }

    assert_includes error.message, "constant path ending in Controller"
    assert_no_file "config/initializers/hitch.rb"
    assert_equal ROUTES, read("config/routes.rb")
  end

  test "collisions refuse the whole install before writing anything" do
    mkdir_p("#{destination_root}/config/initializers")
    File.write("#{destination_root}/config/initializers/hitch.rb", "# host-owned\n")

    error = assert_raises(Thor::Error) { invoke_generator! }

    assert_includes error.message, "file collision: config/initializers/hitch.rb"
    assert_no_file "app/controllers/mcp_controller.rb"
    assert_no_file "app/tools/mcp_tool_registry.rb"
    assert_equal ROUTES, read("config/routes.rb")
  end

  test "an existing engine mount is not duplicated and the route still precedes it" do
    File.write(
      "#{destination_root}/config/routes.rb",
      "Rails.application.routes.draw do\n  mount Hitch::Engine => \"/\"\nend\n"
    )

    invoke_generator!

    routes = read("config/routes.rb")
    assert_equal 1, routes.scan("mount Hitch::Engine").length
    assert_operator routes.index('match "/mcp"'), :<, routes.index("mount Hitch::Engine")
  end

  test "an existing host-owned /mcp route is left alone" do
    File.write(
      "#{destination_root}/config/routes.rb",
      "Rails.application.routes.draw do\n  post \"mcp\", to: \"legacy#dispatch\"\nend\n"
    )

    invoke_generator!

    routes = read("config/routes.rb")
    refute_includes routes, "mcp#handle"
    assert_includes routes, 'post "mcp", to: "legacy#dispatch"'
    assert_includes routes, "mount Hitch::Engine"
  end

  test "destroy removes the generated files and /mcp route but leaves the mount" do
    invoke_generator!
    invoke_generator!([], behavior: :revoke)

    assert_no_file "config/initializers/hitch.rb"
    assert_no_file "app/controllers/mcp_controller.rb"
    assert_no_file "app/tools/mcp_tool_registry.rb"
    routes = read("config/routes.rb")
    refute_includes routes, 'match "/mcp"'
    # Without an install record, a generated mount and a host-owned one are
    # indistinguishable, so destroy never deletes mounts.
    assert_includes routes, "mount Hitch::Engine"
  end

  test "destroy never removes a pre-existing engine mount" do
    File.write(
      "#{destination_root}/config/routes.rb",
      "Rails.application.routes.draw do\n  mount Hitch::Engine => \"/\"\nend\n"
    )
    invoke_generator!

    invoke_generator!([], behavior: :revoke)

    routes = read("config/routes.rb")
    assert_equal 1, routes.scan("mount Hitch::Engine").length
    refute_includes routes, 'match "/mcp"'
    assert_no_file "config/initializers/hitch.rb"
  end

  test "destroy after the host already owned /mcp leaves the host route intact" do
    File.write(
      "#{destination_root}/config/routes.rb",
      "Rails.application.routes.draw do\n  post \"mcp\", to: \"legacy#dispatch\"\nend\n"
    )
    invoke_generator!

    invoke_generator!([], behavior: :revoke)

    routes = read("config/routes.rb")
    assert_includes routes, 'post "mcp", to: "legacy#dispatch"'
    refute_includes routes, "mcp#handle"
    assert_no_file "config/initializers/hitch.rb"
    assert_no_file "app/controllers/mcp_controller.rb"
  end

  test "a missing routes file refuses before writing anything" do
    File.delete("#{destination_root}/config/routes.rb")

    error = assert_raises(Thor::Error) { invoke_generator! }

    assert_includes error.message, "routes.draw"
    assert_no_file "config/initializers/hitch.rb"
    assert_no_file "app/controllers/mcp_controller.rb"
    assert_no_file "app/tools/mcp_tool_registry.rb"
  end

  test "the library CIMD fallback stays false, so upgrading changes nothing" do
    Hitch.reset_configuration!
    assert_equal false, Hitch.configuration.client_id_metadata_enabled
  ensure
    Hitch.reset_configuration!
  end

  private

  def invoke_generator!(arguments = [], behavior: :invoke)
    run_generator(arguments, { behavior:, debug: true })
  end

  def generated_initializer
    read("config/initializers/hitch.rb")
  end

  def read(relative_path)
    File.read(File.expand_path(relative_path, destination_root))
  end
end
