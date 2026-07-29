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

    # CIMD leans on Rails.cache for two things that are not conveniences:
    # negative caching, which stops a dead or hostile client_id buying an
    # outbound request per inbound one, and the per-principal fetch rate
    # limit. A NullStore retains neither, so both simply do not apply —
    # silently, and precisely on the deployment that thinks it is
    # protected. The in-process concurrency cap still holds, so this is a
    # warning rather than a refusal, but it is worth saying out loud.
    initializer "hitch.warn_on_uncacheable_cimd", after: :initialize_cache do
      next unless Hitch.configuration.client_id_metadata_enabled
      next unless defined?(ActiveSupport::Cache::NullStore)
      next unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      Rails.logger&.warn(
        "[hitch] client_id_metadata_enabled is on but Rails.cache is a NullStore. " \
        "Client metadata documents will be refetched on every authorize request, " \
        "negative caching will not limit a dead or hostile client_id, and the " \
        "per-principal fetch rate limit will not apply. Configure a real cache store."
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
