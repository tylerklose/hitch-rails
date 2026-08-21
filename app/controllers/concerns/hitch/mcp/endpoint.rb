# frozen_string_literal: true

require "json"

module Hitch
  module MCP
    # Authenticated, stateless MCP 2026-07-28 JSON endpoint for a dedicated
    # host-owned ActionController::API controller.
    module Endpoint
      extend ActiveSupport::Concern

      include Hitch::RequestAdmission

      included do
        skip_forgery_protection if respond_to?(:skip_forgery_protection)

        prepend_before_action :hitch_mcp_gate!, only: :handle
        prepend_around_action :hitch_mcp_observe_request,
          only: :handle,
          unless: -> { request.options? }
      end

      def handle
        return hitch_mcp_protocol_error!(415, -32600, "Invalid Request") unless
          Internal::MediaType.json_content_type?(request.get_header("CONTENT_TYPE"))
        return hitch_mcp_protocol_error!(406, -32600, "Invalid Request") unless
          Internal::MediaType.accepts_required_types?(request.get_header("HTTP_ACCEPT"))

        max_request_bytes = Hitch.configuration.mcp.max_request_bytes
        raw_body = hitch_read_bounded_request_body(max_request_bytes)
        @hitch_mcp_observation&.request_bytes!(raw_body ? raw_body.bytesize : max_request_bytes + 1)
        return hitch_mcp_protocol_error!(413, -32600, "Invalid Request") unless raw_body

        verified_request = Internal::VerifiedRequest.call(
          raw_body: raw_body,
          headers: {
            protocol_version: request.get_header("HTTP_MCP_PROTOCOL_VERSION"),
            method: request.get_header("HTTP_MCP_METHOD"),
            name: request.get_header("HTTP_MCP_NAME")
          }
        )
        @hitch_mcp_observation&.verified!(verified_request)

        hitch_mcp_dispatch!(verified_request)
      rescue Internal::VerifiedRequest::Failure => error
        hitch_mcp_protocol_error!(
          error.http_status,
          error.code,
          error.message,
          request_id: error.request_id,
          data: error.data
        )
      rescue StandardError => error
        request_id = verified_request && verified_request["id"]
        Internal::EndpointErrorReporter.report(category: :dispatch)
        Internal::LocalDiagnosis.report("MCP request failed during dispatch", error)
        hitch_mcp_protocol_error!(200, -32603, "Internal error", request_id: request_id)
      ensure
        request.delete_header("RAW_POST_DATA") if request
      end

      private

      # ActionController instrumentation reads both body parameters and format
      # before callbacks. Seed safe caches first; Hitch validates the raw body
      # and Accept header itself after admission.
      def process_action(action_name, ...)
        if action_name.to_s == "handle"
          request.request_parameters = {}
          request.formats = [ :json ]
        end

        super
      end

      def hitch_mcp_observe_request
        Internal::Observation.with_request_state do |state|
          @hitch_mcp_observation = state
          yield
        end
      ensure
        begin
          hitch_mcp_request_observed!
        ensure
          @hitch_mcp_observation = nil
        end
      end

      # The security order, top to bottom. Each gate halts the request by
      # rendering; nothing later runs once one has.
      def hitch_mcp_gate!
        hitch_mcp_host_gate!
        return if performed?

        hitch_mcp_origin_gate!
        return if performed?

        hitch_mcp_method_gate!
        return if performed?

        hitch_mcp_authenticate!
        return if performed?

        hitch_mcp_rate_admission!
      end

      def hitch_mcp_host_gate!
        hitch_mcp_append_vary!("Origin")
        if request.options?
          hitch_mcp_append_vary!("Access-Control-Request-Method")
          hitch_mcp_append_vary!("Access-Control-Request-Headers")
        end
        return if Internal::HostAuthority.allowed?(request)

        head :bad_request
      end

      def hitch_mcp_origin_gate!
        origin = request.get_header("HTTP_ORIGIN")
        return hitch_mcp_origin_denied! if request.options? && origin.nil?
        return if origin.nil?
        return hitch_mcp_origin_denied! unless Internal::CorsPolicy.origin_allowed?(origin)
        return if request.options?

        response.headers["Access-Control-Allow-Origin"] = origin
      end

      def hitch_mcp_method_gate!
        return hitch_mcp_preflight! if request.options?
        return if request.post?

        response.headers["Allow"] = "POST, OPTIONS"
        head :method_not_allowed
      end

      def hitch_mcp_authenticate!
        raw_token = Internal::BearerChallenge.token(request.get_header("HTTP_AUTHORIZATION"))
        return hitch_mcp_unauthorized! unless raw_token

        access_token = Hitch::AccessToken.find_by_token(raw_token)
        resource = Hitch.configuration.resource_uri
        client_id = access_token&.client_id
        valid = access_token&.valid_for_resource?(resource) &&
          client_id.is_a?(String) && !client_id.empty?
        return hitch_mcp_unauthorized! unless valid

        principal = hitch_mcp_token_principal(access_token)
        return hitch_mcp_unauthorized! unless principal

        @hitch_mcp_access_token = access_token
        @hitch_mcp_principal = principal
        @hitch_mcp_client_id = client_id.dup.freeze
        @hitch_mcp_resource = resource.dup.freeze
        @hitch_mcp_granted_scopes = access_token.scopes.to_s.split.map { |scope| scope.dup.freeze }.freeze
        @hitch_mcp_observation&.authenticated!(principal:, client_id:)
      rescue StandardError
        Internal::EndpointErrorReporter.report(category: :authentication)
        head :service_unavailable
      end

      def hitch_mcp_token_principal(access_token)
        access_token.principal
      rescue ActiveRecord::RecordNotFound, NameError
        nil
      end

      def hitch_mcp_rate_admission!
        limit = Hitch.configuration.mcp.request_limit
        count = hitch_mcp_admit_authenticated_request(
          principal: @hitch_mcp_principal,
          client_id: @hitch_mcp_client_id
        )
        return if count.nil? || count <= limit.fetch(:to)

        response.headers["Retry-After"] = limit.fetch(:within).to_s
        response.headers["Access-Control-Expose-Headers"] = "Retry-After"
        head :too_many_requests
      # NotImplementedError is a ScriptError, not a StandardError: the base
      # ActiveSupport::Cache::Store#increment raises it, and every subclass
      # answers respond_to?(:increment), so a store that never overrode it
      # passes validation and surfaces here.
      rescue NotImplementedError, StandardError
        Internal::EndpointErrorReporter.report(category: :request_admission)
        head :service_unavailable
      end

      def hitch_mcp_dispatch!(verified_request)
        scope = hitch_mcp_resolve_scope
        context = hitch_mcp_context(verified_request, scope:)
        server_info = Hitch.configuration.mcp.server_info

        snapshot = Hitch.configuration.mcp.registry_snapshot!
        tools = hitch_mcp_tools(verified_request:, context:, snapshot:)
        return if performed?

        protocol_response = Internal::SDKAdapter.call(
          verified_request: verified_request,
          tools: tools,
          context: context,
          server_info: server_info
        )
        hitch_mcp_render_protocol!(protocol_response, status: 200)
      end

      def hitch_mcp_resolve_scope
        resolver = Hitch.configuration.mcp.scope_resolver
        return nil unless resolver

        resolver.call(
          principal: @hitch_mcp_principal,
          access_token: @hitch_mcp_access_token,
          request: request
        )
      end

      def hitch_mcp_context(verified_request, scope:)
        metadata = verified_request.fetch("params").fetch("_meta")
        Context.new(
          principal: @hitch_mcp_principal,
          access_token: @hitch_mcp_access_token,
          scope: scope,
          granted_scopes: @hitch_mcp_granted_scopes,
          client_id: @hitch_mcp_client_id,
          resource: @hitch_mcp_resource,
          request_id: verified_request.fetch("id"),
          remote_ip: request.remote_ip,
          user_agent: request.user_agent,
          protocol_version: metadata.fetch("io.modelcontextprotocol/protocolVersion"),
          meta: metadata
        )
      end

      def hitch_mcp_protocol_error!(status, code, message, request_id: nil, data: nil)
        error = { code: code, message: message }
        error[:data] = data if data
        hitch_mcp_render_protocol!(
          { jsonrpc: "2.0", id: request_id, error: error },
          status: status
        )
      end

      def hitch_mcp_render_protocol!(protocol_response, status:)
        @hitch_mcp_observation&.protocol_response!(protocol_response)
        render body: JSON.generate(protocol_response), status: status, content_type: "application/json"
      end

      def hitch_mcp_origin_denied!
        response.headers.delete("Access-Control-Allow-Origin")
        head :forbidden
      end

      def hitch_mcp_preflight!
        allowed = Internal::CorsPolicy.preflight_allowed?(
          requested_method: request.get_header("HTTP_ACCESS_CONTROL_REQUEST_METHOD"),
          requested_headers: request.get_header("HTTP_ACCESS_CONTROL_REQUEST_HEADERS")
        )
        return hitch_mcp_origin_denied! unless allowed

        response.headers["Access-Control-Allow-Origin"] = request.get_header("HTTP_ORIGIN")
        Internal::CorsPolicy::PREFLIGHT_RESPONSE_HEADERS.each do |header, value|
          response.headers[header] = value
        end
        head :no_content
      end

      def hitch_mcp_unauthorized!
        response.headers["WWW-Authenticate"] = Internal::BearerChallenge.challenge
        response.headers["Access-Control-Expose-Headers"] = "WWW-Authenticate"
        head :unauthorized
      end

      def hitch_mcp_insufficient_scope!(required_scopes)
        response.headers["WWW-Authenticate"] =
          Internal::BearerChallenge.insufficient_scope(required_scopes)
        response.headers["Access-Control-Expose-Headers"] = "WWW-Authenticate"
        head :forbidden
      end

      def hitch_mcp_append_vary!(value)
        values = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        values << value unless values.include?(value)
        response.headers["Vary"] = values.join(", ")
      end

      def hitch_mcp_tools(verified_request:, context:, snapshot:)
        if verified_request.fetch("method") == "tools/call"
          resolution = Internal::RegistryRuntime.runtime_call(
            snapshot:,
            name: verified_request.fetch("params").fetch("name"),
            context:
          )
          if %i[available insufficient_scope].include?(resolution.status)
            @hitch_mcp_observation&.tool_resolved!(verified_request.fetch("params").fetch("name"))
          end
          if resolution.status == :insufficient_scope
            hitch_mcp_insufficient_scope!(resolution.required_scopes)
            return [].freeze
          end

          return resolution.status == :available ? [ resolution.tool ].freeze : [].freeze
        end

        Internal::RegistryRuntime.runtime_listing(snapshot:, context:)
      end

      # Counts through the host application's own cache store, exactly as
      # ActionController::RateLimiting does. A nil count admits, same as
      # Rails: :null_store returns nil (test, and development without
      # caching — production refuses those stores at boot), and Redis and
      # Solid Cache stores return nil during a backend outage rather than
      # raising. This request is already authenticated, so an outage widens
      # one token holder's quota, not the front door. Anything else a store
      # returns fails the comparison above and becomes a 503.
      def hitch_mcp_admit_authenticated_request(principal:, client_id:)
        configuration = Hitch.configuration.mcp
        configuration.rate_limit_store.increment(
          RateLimitKey.call(principal:, client_id:),
          expires_in: configuration.request_limit.fetch(:within)
        )
      end

      def hitch_mcp_request_observed!
        @hitch_mcp_observation&.finish!(response:)
      end
    end
  end
end
