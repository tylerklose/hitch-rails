# frozen_string_literal: true

module Hitch
  class Engine < ::Rails::Engine
    isolate_namespace Hitch

    class << self
      def doctor_command?
        ARGV.reject { |argument| argument.start_with?("-") } == [ "hitch:doctor" ]
      end
    end

    initializer "hitch.zeitwerk_inflections", before: :set_autoloaders do
      Rails.autoloaders.main.inflector.inflect(
        "mcp" => "MCP",
        "sdk_adapter" => "SDKAdapter"
      )
    end

    # Rack::MethodOverride would otherwise parse OAuth form bodies before the
    # controller-level strict admission boundary can cap or redact them.
    # Anchored to ActionDispatch::Executor because it is present in both the
    # full and api_only stacks (Rack::MethodOverride is not) and sits upstream
    # of every body-reading middleware.
    initializer "hitch.guard_oauth_forms", before: :build_middleware_stack do |app|
      app.middleware.insert_after ActionDispatch::Executor, Hitch::RackFormGuard
    end

    # Host apps see the engine's migrations via db:migrate without needing
    # to copy them — the install generator only writes the initializer.
    initializer :append_migrations do |app|
      next if app.root.to_s == root.to_s
      # Skipped when ENGINE_ROOT is defined, which means the process was
      # driven through `rails/tasks/engine.rake` — this gem's own
      # Rakefile, never a host app's. ActiveRecord's own db:load_config
      # hook (activerecord/railtie.rb) then appends the engine's
      # db/migrate to DatabaseTasks.migrations_paths with `+=`, no
      # dedupe. Contributing it here as well puts the directory in that
      # collection twice, and ActiveRecord::Schema.define raises
      # "Duplicate migration" as it walks them.
      #
      # Latent until a schema is actually reloaded — which is to say
      # until someone adds a migration, at which point every subsequent
      # one hits it.
      next if defined?(ENGINE_ROOT)

      config.paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
    end

    # CIMD leans on Rails.cache for negative caching, which is what stops
    # a dead or hostile client_id buying an outbound request per inbound
    # one. A NullStore retains nothing between requests, so that guard is
    # silently absent — precisely on the deployment that thinks it is
    # protected.
    #
    # The concurrency cap and the per-principal rate limit are both
    # in-process and unaffected, which is why this warns rather than
    # refuses.
    initializer "hitch.warn_on_uncacheable_cimd", after: :initialize_cache do
      next unless Hitch.configuration.client_id_metadata_enabled
      # Production only. :null_store is Rails' default in test, and in
      # development without tmp/caching-dev.txt, so warning everywhere
      # would fire on every console, rake task and test run — training
      # adopters to silence it in the one environment it matters.
      next unless Rails.env.production?
      next unless defined?(ActiveSupport::Cache::NullStore)
      next unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      Rails.logger&.warn(
        "[hitch] client_id_metadata_enabled is on but Rails.cache is a NullStore. " \
        "Client metadata documents will be refetched on every authorize request, and " \
        "negative caching will not limit a dead or hostile client_id. The concurrency " \
        "cap and per-principal rate limit are unaffected. Configure a real cache store."
      )
    end

    initializer "hitch.validate_dynamic_client_registration", after: :load_config_initializers do
      configuration = Hitch.configuration
      next unless configuration.dynamic_client_registration_enabled
      next if Hitch::Engine.doctor_command?

      unless configuration.dynamic_client_registration_enabled_configured?
        Rails.logger&.warn(
          "[hitch] Dynamic Client Registration is enabled by the compatibility default. " \
          "Set config.dynamic_client_registration_enabled explicitly. Production requires " \
          "the registration rate store (config.dynamic_client_registration_rate_store, " \
          "default: your cache store) to count across processes; new installs disable DCR."
        )
      end

      next unless Rails.env.production?

      Hitch::RateLimitStore.assert_shared!(
        configuration.dynamic_client_registration_rate_store,
        setting: Hitch::DynamicRegistrationRateLimit::SETTING
      )
    end

    initializer "hitch.validate_configuration", after: :load_config_initializers do
      # A fresh host has to boot once to run this generator, and the
      # initializer it creates is what sets resource_uri. Keep the exception
      # exact: other generators and every ordinary application boot still
      # validate and fail closed.
      install_generator = ARGV.first == "hitch:install" ||
        (%w[generate g].include?(ARGV.first) && ARGV[1] == "hitch:install")
      next if install_generator || Hitch::Engine.doctor_command?

      Hitch.configuration.validate!
    end

    config.to_prepare do
      configuration = Hitch.configuration
      next if Hitch::Engine.doctor_command?
      next unless configuration.resource_uri.present?
      next unless configuration.mcp.__send__(:runtime_configured?)

      configuration.mcp.validate!

      configuration.mcp.__send__(
        :prepare_registry!,
        supported_scopes: configuration.supported_scopes
      )
      configuration.mcp.validate_rate_limit_store!
    end

    # Filter OAuth secrets out of Rails request logs. Without this, a
    # crash on /oauth/token would log the raw code + code_verifier
    # (both lookup credentials), and a successful response would log
    # the issued access_token. None should ever appear in logs.
    #
    # :token is included because POST /oauth/revoke receives the live
    # bearer token in params[:token] (RFC 7009) — without filtering it,
    # the gem's own revoke endpoint would log usable access tokens. The
    # filter matches param names, so a host's unrelated :token params
    # are also redacted from logs; for a secret-bearing name that is the
    # safe default, not a regression.
    initializer "hitch.filter_parameters" do |app|
      app.config.filter_parameters += [
        :code,
        :code_verifier,
        :client_secret,
        :client_secret_digest,
        :access_token,
        :authorization_code,
        :token
      ]
    end
  end
end
