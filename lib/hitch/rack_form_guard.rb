# frozen_string_literal: true

require "stringio"
require "uri"

module Hitch
  # Rack::MethodOverride parses every form POST before Rails dispatches a
  # controller. Hitch's OAuth endpoints and final MCP endpoint own stricter raw
  # body parsers, so pre-populate Rack's form cache only when Rails resolves the
  # request to one of those actions. Resolving ownership matters: Rails accepts
  # format/trailing-slash variants, host routes may shadow the engine, and the
  # MCP controller/route remain host-owned.
  class RackFormGuard
    REQUEST_FORM_HASH = Rack::RACK_REQUEST_FORM_HASH
    REQUEST_FORM_INPUT = Rack::RACK_REQUEST_FORM_INPUT
    # Rack 2 reads only form_hash and does not define the pairs key.
    REQUEST_FORM_PAIRS = if Rack.const_defined?(:RACK_REQUEST_FORM_PAIRS)
      Rack::RACK_REQUEST_FORM_PAIRS
    else
      "rack.request.form_pairs"
    end

    ENDPOINTS = {
      "hitch/authorizations" => "create",
      "hitch/registrations" => "create",
      "hitch/revocations" => "create",
      "hitch/tokens" => "create",
      "hitch/device_authorizations" => "create",
      "hitch/activations" => "create"
    }.freeze
    # /activate is anchored to the root: the /oauth/* names are distinctive
    # enough to probe as suffixes under any mount, but bare "activate" is a
    # common host member-action name, and the engine's well-known routes
    # already require a root mount.
    OAUTH_CANDIDATE_PATH =
      %r{/oauth/(?:authorize|register|revoke|token|device_authorization)(?:\.[^/]*)?/?\z|\A/+activate(?:\.[^/]*)?/?\z}

    def initialize(app, routes: -> { Rails.application.routes })
      @app = app
      @routes = routes
    end

    def call(environment)
      route_type = hitch_strict_body_route(environment)
      if route_type
        environment[REQUEST_FORM_HASH] = {}
        environment[REQUEST_FORM_INPUT] = environment[Rack::RACK_INPUT]
        environment[REQUEST_FORM_PAIRS] = []
        # The MCP route is permanently POST/OPTIONS. A generic Rack method
        # override must neither parse its body nor turn authenticated POST
        # traffic into an unauthenticated OPTIONS request.
        environment.delete("HTTP_X_HTTP_METHOD_OVERRIDE") if route_type == :mcp
      end

      @app.call(environment)
    end

    private

    def hitch_strict_body_route(environment)
      return false unless environment[Rack::REQUEST_METHOD] == "POST"

      # Match RouteSet#call exactly before narrowing the ownership probe. Rails
      # collapses repeated slashes but deliberately does not resolve dot
      # segments; applying the candidate filter to raw PATH_INFO would miss
      # routes Rails later dispatches.
      normalized_path = ActionDispatch::Journey::Router::Utils.normalize_path(environment[Rack::PATH_INFO])
      return false unless hitch_candidate_path?(normalized_path)

      # Route recognition must not share the credential-bearing input or
      # path-parameter cache with the request Rails will actually dispatch.
      # Host route constraints still receive the real method/host/headers, but
      # cannot become an earlier body reader through this ownership probe.
      probe_environment = environment.dup
      probe_environment.delete("action_dispatch.request.path_parameters")
      probe_environment["rack.input"] = StringIO.new
      probe_environment[REQUEST_FORM_HASH] = {}
      probe_environment[REQUEST_FORM_INPUT] = probe_environment[Rack::RACK_INPUT]
      probe_environment[REQUEST_FORM_PAIRS] = []
      probe_environment["CONTENT_LENGTH"] = "0"
      probe_environment[Rack::PATH_INFO] = normalized_path

      request = ActionDispatch::Request.new(probe_environment)
      parameters = route_set.recognize_path_with_request(
        request,
        normalized_path,
        {},
        raise_on_missing: false
      )
      return false unless parameters
      return :oauth if hitch_oauth_endpoint?(parameters)
      return :mcp if hitch_mcp_endpoint?(parameters)

      false
    rescue ActionController::RoutingError
      false
    end

    def route_set
      @routes.respond_to?(:call) ? @routes.call : @routes
    end

    def hitch_oauth_endpoint?(parameters)
      ENDPOINTS[parameters[:controller]] == parameters[:action]
    end

    def hitch_mcp_endpoint?(parameters)
      return false unless parameters[:action] == "handle"

      controller_name = parameters[:controller].to_s
      return false if controller_name.empty?

      controller = "#{controller_name.camelize}Controller".safe_constantize
      controller && controller.ancestors.include?(Hitch::MCP::Endpoint)
    end

    def hitch_candidate_path?(path)
      return true if OAUTH_CANDIDATE_PATH.match?(path)

      resource_path = URI.parse(Hitch.configuration.resource_uri.to_s).path
      resource_path = "/" if resource_path.empty?
      %r{\A#{Regexp.escape(resource_path)}(?:\.[^/]*)?/?\z}.match?(path)
    rescue URI::InvalidURIError
      false
    end
  end
end
