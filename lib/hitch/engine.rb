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
