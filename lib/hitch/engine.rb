# frozen_string_literal: true

module Hitch
  class Engine < ::Rails::Engine
    isolate_namespace Hitch

    # Host apps see the engine's migrations via db:migrate without needing
    # to copy them — the install generator only writes the initializer.
    initializer :append_migrations do |app|
      next if app.root.to_s == root.to_s

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
        :access_token,
        :authorization_code,
        :token
      ]
    end
  end
end
