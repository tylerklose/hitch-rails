# frozen_string_literal: true

require "test_helper"
require "open3"

class Hitch::EngineApiOnlyBootTest < ActiveSupport::TestCase
  # API-only apps have no Rack::MethodOverride, so anchoring the form guard
  # to it raised at boot ("No such middleware to insert before"). Boot a real
  # api_only application in a subprocess — the dummy app only covers the
  # full stack.
  BOOT_SCRIPT = <<~RUBY
    require "bundler/setup"
    require "fileutils"
    require "tmpdir"
    require "action_controller/railtie"
    require "hitch"

    # An explicit empty root: without one Rails resolves the app root to the
    # gem checkout, adopts the ENGINE's config/routes.rb as the host's, and
    # boot fails on duplicate route names instead of exercising the guard.
    root = Dir.mktmpdir("hitch-api-only-host")
    FileUtils.mkdir_p(File.join(root, "config"))
    File.write(File.join(root, "config/routes.rb"), "Rails.application.routes.draw {}\\n")

    class ApiOnlyHost < Rails::Application
      config.api_only = true
      config.eager_load = false
      config.logger = Logger.new(IO::NULL)
      config.hosts.clear
      config.secret_key_base = "x" * 64
    end

    ApiOnlyHost.config.root = root
    Hitch.configure { |c| c.resource_uri = "https://smoke.test/mcp" }

    ApiOnlyHost.initialize!

    middleware = ApiOnlyHost.middleware.middlewares
    raise "form guard missing from api_only stack" unless middleware.include?(Hitch::RackFormGuard)
    raise "MethodOverride unexpectedly present" if middleware.include?(Rack::MethodOverride)

    puts "API_ONLY_BOOT_OK"
  RUBY

  test "an api_only host boots with the form guard installed" do
    output, status = Open3.capture2e(RbConfig.ruby, "-e", BOOT_SCRIPT)

    assert status.success?, "api_only boot failed:\n#{output}"
    assert_includes output, "API_ONLY_BOOT_OK"
  end
end
