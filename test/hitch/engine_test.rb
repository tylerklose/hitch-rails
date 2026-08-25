# frozen_string_literal: true

require "test_helper"

class Hitch::EngineTest < ActiveSupport::TestCase
  # Stands in for a store shared across processes; MemoryStore and NullStore
  # are refused in production.
  class SharedRateStore < ActiveSupport::Cache::Store
    def increment(name, amount = 1, **options) = 1
  end

  test "host filter_parameters extended with OAuth secrets" do
    # Rails 8 consolidates filter_parameters into a single regex for
    # performance — assert behavior by actually filtering a sample hash
    # rather than introspecting the (post-consolidation) array shape.
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "code" => "raw_auth_code",
      "code_verifier" => "raw_verifier",
      "access_token" => "raw_access_token",
      "authorization_code" => "raw_auth_code",
      "token" => "raw_token",
      "device_code" => "raw_device_code",
      "user_code" => "WDJB-MJHT",
      "client_name" => "Claude"  # control: not filtered
    )
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "[FILTERED]", filtered["code_verifier"]
    assert_equal "[FILTERED]", filtered["access_token"]
    assert_equal "[FILTERED]", filtered["authorization_code"]
    assert_equal "[FILTERED]", filtered["token"]
    assert_equal "[FILTERED]", filtered["device_code"]
    assert_equal "[FILTERED]", filtered["user_code"]
    assert_equal "Claude", filtered["client_name"]
  end

  test "OAuth form guard runs before Rack method override" do
    middlewares = Rails.application.middleware.map(&:klass)
    guard_index = middlewares.index(Hitch::RackFormGuard)
    override_index = middlewares.index(Rack::MethodOverride)

    assert guard_index
    assert override_index
    assert_operator guard_index, :<, override_index
  end

  test "OAuth form guard follows Rails route ownership for path variants" do
    captured = []
    downstream = lambda do |environment|
      captured << environment[Rack::RACK_REQUEST_FORM_HASH]
      [ 200, {}, [] ]
    end
    guard = Hitch::RackFormGuard.new(downstream)

    %w[
      /oauth/authorize.json
      /oauth/authorize/
      /oauth/register.json
      /oauth/register/
      /oauth/revoke.json
      /oauth/revoke/
      /oauth/token.json
      /oauth/token/
      /oauth//token
      /oauth/token//
      /oauth/device_authorization.json
      /oauth/device_authorization/
      /activate.json
      /activate/
    ].each do |path|
      guard.call(Rack::MockRequest.env_for(path, method: "POST", input: "code=secret"))
    end
    guard.call(Rack::MockRequest.env_for("/host/oauth/token", method: "POST", input: "ordinary=value"))
    # A host's own member action named activate is not even a candidate:
    # bare "activate" is too common a route name to probe as a suffix.
    guard.call(Rack::MockRequest.env_for("/subscriptions/1/activate", method: "POST", input: "plan=pro"))

    assert_equal Array.new(14) { {} }, captured.first(14)
    assert_nil captured[14]
    assert_nil captured.last
  end

  test "form guard owns the host MCP route before Rack method override" do
    Hitch.reset_configuration!
    Hitch.configuration.resource_uri = "https://dummy.test/mcp"
    captured = nil
    downstream = lambda do |environment|
      captured = environment
      [ 200, {}, [] ]
    end
    guard = Hitch::RackFormGuard.new(downstream)
    environment = Rack::MockRequest.env_for(
      "https://dummy.test/mcp",
      method: "POST",
      input: "_method=OPTIONS&secret=body"
    )
    environment["HTTP_X_HTTP_METHOD_OVERRIDE"] = "OPTIONS"

    guard.call(environment)

    assert_equal({}, captured.fetch(Rack::RACK_REQUEST_FORM_HASH))
    assert_equal [], captured.fetch(Rack::RACK_REQUEST_FORM_PAIRS)
    refute captured.key?("HTTP_X_HTTP_METHOD_OVERRIDE")
  ensure
    Hitch.reset_configuration!
    Hitch.configuration.resource_uri = "https://dummy.test/mcp"
  end

  test "admission owns process_action before Rails instrumentation" do
    {
      Hitch::AuthorizationsController => Hitch::OauthFormAdmission,
      Hitch::TokensController => Hitch::OauthFormAdmission,
      Hitch::RevocationsController => Hitch::OauthFormAdmission,
      Hitch::RegistrationsController => Hitch::RegistrationAdmission
    }.each do |controller, admission|
      ancestors = controller.ancestors
      assert_equal admission, controller.instance_method(:process_action).owner
      assert_operator ancestors.index(admission), :<, ancestors.index(ActionController::Instrumentation)
    end
  end

  # ActiveRecord's own db:load_config hook appends the engine's
  # db/migrate to DatabaseTasks.migrations_paths with `+=` and no dedupe
  # whenever ENGINE_ROOT is defined. If the engine's append_migrations
  # initializer contributes the same directory, it lands in that
  # collection twice and ActiveRecord::Schema.define raises "Duplicate
  # migration" while walking it — latent until a schema reload, which is
  # to say until someone adds a migration.
  test "no migration path is contributed twice" do
    paths = ActiveRecord::Tasks::DatabaseTasks.migrations_paths.map { |p| File.expand_path(p) }
    assert_equal paths.uniq, paths, "a duplicated migration path breaks every schema load"

    app_paths = Rails.application.config.paths["db/migrate"].expanded.map { |p| File.expand_path(p) }
    assert_equal app_paths.uniq, app_paths
  end

  # The guard reads client_id_metadata_enabled, which only the host's
  # config/initializers can set — so the initializer must sort after
  # :load_config_initializers in the boot graph, and the warning must
  # actually fire on the production + NullStore + CIMD posture.
  test "the CIMD NullStore warning runs after host initializers and fires in production" do
    ordered = Rails.application.initializers.tsort.map(&:name)
    assert_operator ordered.index("hitch.warn_on_uncacheable_cimd"), :>,
      ordered.index(:load_config_initializers)

    Hitch.reset_configuration!
    Hitch.configuration.client_id_metadata_enabled = true
    production = ActiveSupport::EnvironmentInquirer.new("production")
    null_store = ActiveSupport::Cache::NullStore.new
    messages = []
    original_logger = Rails.logger
    Rails.logger = Class.new { define_method(:warn) { |message| messages << message } }.new

    stub_class_method(Rails, :env, -> { production }) do
      stub_class_method(Rails, :cache, -> { null_store }) do
        cimd_warning_initializer.run(Rails.application)
      end
    end

    assert_equal 1, messages.length
    assert_includes messages.first, "NullStore"
  ensure
    Rails.logger = original_logger
    Hitch.reset_configuration!
  end

  test "implicit DCR compatibility posture emits one actionable boot warning" do
    Hitch.reset_configuration!
    messages = []
    original_logger = Rails.logger
    Rails.logger = Class.new { define_method(:warn) { |message| messages << message } }.new

    dynamic_registration_initializer.run(Rails.application)

    assert_equal 1, messages.length
    assert_includes messages.first, "dynamic_client_registration_enabled"
    assert_includes messages.first, "dynamic_client_registration_rate_store"
  ensure
    Rails.logger = original_logger
    Hitch.reset_configuration!
  end

  test "production boot refuses enabled DCR without a shared atomic store" do
    Hitch.reset_configuration!
    Hitch.configuration.dynamic_client_registration_enabled = true
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      assert_raises(ArgumentError) do
        dynamic_registration_initializer.run(Rails.application)
      end
    end
  ensure
    Hitch.reset_configuration!
  end

  test "production boot accepts the explicit shared-store contract" do
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.dynamic_client_registration_enabled = true
      configuration.dynamic_client_registration_rate_store = SharedRateStore.new
    end
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      assert_nothing_raised { dynamic_registration_initializer.run(Rails.application) }
    end
  ensure
    Hitch.reset_configuration!
  end

  test "doctor alone may bypass production DCR boot refusal so it can report it" do
    Hitch.reset_configuration!
    Hitch.configuration.dynamic_client_registration_enabled = true
    production = ActiveSupport::EnvironmentInquirer.new("production")
    original_arguments = ARGV.dup
    ARGV.replace([ "hitch:doctor" ])

    stub_class_method(Rails, :env, -> { production }) do
      assert_nothing_raised { dynamic_registration_initializer.run(Rails.application) }
    end
  ensure
    ARGV.replace(original_arguments) if original_arguments
    Hitch.reset_configuration!
  end

  test "boot refuses a missing canonical resource URI with an actionable error" do
    Hitch.reset_configuration!

    error = assert_raises(ArgumentError) do
      configuration_initializer.run(Rails.application)
    end
    assert_includes error.message, "resource_uri is required"
  ensure
    Hitch.reset_configuration!
  end

  test "boot refuses an enabled MCP runtime without a registry" do
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.mcp.enabled = true
    end

    error = assert_raises(ArgumentError) do
      configuration_initializer.run(Rails.application)
    end
    assert_includes error.message, "mcp.registry is required"

    Hitch.configuration.mcp.registry = "McpToolRegistry"
    assert_nothing_raised { configuration_initializer.run(Rails.application) }

    # Setting runtime knobs without the switch configures nothing at boot.
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.mcp.server_info = { name: "dummy", version: "1" }
    end
    assert_nothing_raised { configuration_initializer.run(Rails.application) }
  ensure
    Hitch.reset_configuration!
  end

  test "only the install generator and doctor may boot before the initializer exists" do
    Hitch.reset_configuration!
    original_arguments = ARGV.dup

    ARGV.replace([ "generate", "hitch:install" ])
    assert_nothing_raised { configuration_initializer.run(Rails.application) }

    ARGV.replace([ "hitch:install" ])
    assert_nothing_raised { configuration_initializer.run(Rails.application) }

    ARGV.replace([ "hitch:doctor" ])
    assert_nothing_raised { configuration_initializer.run(Rails.application) }

    ARGV.replace([ "hitch:doctor", "db:migrate" ])
    assert_raises(ArgumentError) { configuration_initializer.run(Rails.application) }

    ARGV.replace([ "generate", "unrelated" ])
    assert_raises(ArgumentError) { configuration_initializer.run(Rails.application) }
  ensure
    ARGV.replace(original_arguments) if original_arguments
    Hitch.reset_configuration!
  end

  private

  test "production boot refuses enabled device authorization without a shared atomic store" do
    Hitch.reset_configuration!
    Hitch.configuration.device_authorization_enabled = true
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      assert_raises(ArgumentError) do
        device_authorization_initializer.run(Rails.application)
      end
    end
  ensure
    Hitch.reset_configuration!
  end

  test "production boot accepts a shared device store, and the disabled flag skips the check" do
    Hitch.reset_configuration!
    Hitch.configuration.device_authorization_enabled = true
    Hitch.configuration.device_authorization_rate_store = SharedRateStore.new
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      assert_nothing_raised { device_authorization_initializer.run(Rails.application) }
    end

    Hitch.reset_configuration!
    stub_class_method(Rails, :env, -> { production }) do
      assert_nothing_raised { device_authorization_initializer.run(Rails.application) }
    end
  ensure
    Hitch.reset_configuration!
  end

  test "doctor alone may bypass the production device boot refusal so it can report it" do
    Hitch.reset_configuration!
    Hitch.configuration.device_authorization_enabled = true
    production = ActiveSupport::EnvironmentInquirer.new("production")
    original_arguments = ARGV.dup
    ARGV.replace([ "hitch:doctor" ])

    stub_class_method(Rails, :env, -> { production }) do
      assert_nothing_raised { device_authorization_initializer.run(Rails.application) }
    end
  ensure
    ARGV.replace(original_arguments) if original_arguments
    Hitch.reset_configuration!
  end

  def cimd_warning_initializer
    Hitch::Engine.initializers.find do |initializer|
      initializer.name == "hitch.warn_on_uncacheable_cimd"
    end
  end

  def dynamic_registration_initializer
    Hitch::Engine.initializers.find do |initializer|
      initializer.name == "hitch.validate_dynamic_client_registration"
    end
  end

  def device_authorization_initializer
    Hitch::Engine.initializers.find do |initializer|
      initializer.name == "hitch.validate_device_authorization"
    end
  end


  def configuration_initializer
    Hitch::Engine.initializers.find do |initializer|
      initializer.name == "hitch.validate_configuration"
    end
  end
end
