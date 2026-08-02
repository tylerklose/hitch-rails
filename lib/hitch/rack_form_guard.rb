# frozen_string_literal: true

require "stringio"

module Hitch
  # Rack::MethodOverride parses every form POST before Rails dispatches a
  # controller. Hitch's OAuth endpoints own a stricter, much smaller raw-body
  # parser, so pre-populate Rack's form cache only when Rails resolves the
  # request to one of those engine actions. Resolving ownership matters: Rails
  # accepts format/trailing-slash variants, and a host route may intentionally
  # shadow a path before the engine mount.
  class RackFormGuard
    ENDPOINTS = {
      "hitch/authorizations" => "create",
      "hitch/registrations" => "create",
      "hitch/revocations" => "create",
      "hitch/tokens" => "create"
    }.freeze
    CANDIDATE_PATH = %r{/(?:oauth)/(?:authorize|register|revoke|token)(?:\.[^/]*)?/?\z}

    def initialize(app, routes: -> { Rails.application.routes })
      @app = app
      @routes = routes
    end

    def call(environment)
      if hitch_oauth_form_route?(environment)
        environment[Rack::RACK_REQUEST_FORM_HASH] = {}
        environment[Rack::RACK_REQUEST_FORM_PAIRS] = []
      end

      @app.call(environment)
    end

    private

    def hitch_oauth_form_route?(environment)
      return false unless environment[Rack::REQUEST_METHOD] == "POST"

      # Match RouteSet#call exactly before narrowing the ownership probe. Rails
      # collapses repeated slashes but deliberately does not resolve dot
      # segments; applying the candidate filter to raw PATH_INFO would miss
      # routes Rails later dispatches.
      normalized_path = ActionDispatch::Journey::Router::Utils.normalize_path(environment[Rack::PATH_INFO])
      return false unless CANDIDATE_PATH.match?(normalized_path)

      # Route recognition must not share the credential-bearing input or
      # path-parameter cache with the request Rails will actually dispatch.
      # Host route constraints still receive the real method/host/headers, but
      # cannot become an earlier body reader through this ownership probe.
      probe_environment = environment.dup
      probe_environment.delete("action_dispatch.request.path_parameters")
      probe_environment["rack.input"] = StringIO.new
      probe_environment[Rack::RACK_REQUEST_FORM_HASH] = {}
      probe_environment[Rack::RACK_REQUEST_FORM_PAIRS] = []
      probe_environment["CONTENT_LENGTH"] = "0"
      probe_environment[Rack::PATH_INFO] = normalized_path

      request = ActionDispatch::Request.new(probe_environment)
      parameters = route_set.recognize_path_with_request(
        request,
        normalized_path,
        {},
        raise_on_missing: false
      )
      parameters && ENDPOINTS[parameters[:controller]] == parameters[:action]
    rescue ActionController::RoutingError
      false
    end

    def route_set
      @routes.respond_to?(:call) ? @routes.call : @routes
    end
  end
end
