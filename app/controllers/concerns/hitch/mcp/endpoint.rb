# frozen_string_literal: true

require "json"
require "uri"

module Hitch
  module MCP
    # Authenticated, stateless MCP 2026-07-28 JSON endpoint for a dedicated
    # host-owned ActionController::API controller.
    module Endpoint
      extend ActiveSupport::Concern

      include Hitch::IssuerUrl
      include Hitch::RequestAdmission

      MAX_BEARER_TOKEN_BYTES = 512
      ALLOWED_REQUEST_HEADERS = %w[
        Content-Type
        Authorization
        MCP-Protocol-Version
        Mcp-Method
        Mcp-Name
      ].freeze
      LOOPBACK_ORIGIN = %r{\Ahttps?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z}
      HEADER_CONTROLS = /[\x00-\x08\x0A-\x1F\x7F]/
      ACCEPT_TYPES = %w[application/json text/event-stream].freeze
      SERVER_INFO_KEY_MAP = {
        "name" => "name",
        "version" => "version",
        "title" => "title",
        "instructions" => "instructions",
        name: "name",
        version: "version",
        title: "title",
        instructions: "instructions"
      }.freeze

      included do
        skip_forgery_protection if respond_to?(:skip_forgery_protection)

        # Rails reverses one prepend declaration's method list. This spelling
        # produces Host -> Origin -> method -> auth -> admission at runtime.
        prepend_before_action :hitch_mcp_rate_admission!,
          :hitch_mcp_authenticate!,
          :hitch_mcp_method_gate!,
          :hitch_mcp_origin_gate!,
          :hitch_mcp_host_gate!,
          only: :handle
        prepend_around_action :hitch_mcp_observe_request,
          only: :handle,
          unless: -> { request.options? }
      end

      def handle
        return unless hitch_mcp_media_admitted!

        max_request_bytes = Hitch.configuration.mcp.max_request_bytes
        raw_body = hitch_read_bounded_request_body(max_request_bytes)
        @hitch_mcp_observation&.request_bytes!(raw_body ? raw_body.bytesize : max_request_bytes + 1)
        return hitch_mcp_protocol_error!(413, -32600, "Invalid Request") unless raw_body

        hitch_mcp_body_parse_started!
        verified_request = VerifiedRequest.call(
          raw_body: raw_body,
          headers: {
            protocol_version: request.get_header("HTTP_MCP_PROTOCOL_VERSION"),
            method: request.get_header("HTTP_MCP_METHOD"),
            name: request.get_header("HTTP_MCP_NAME")
          }
        )
        @hitch_mcp_observation&.verified!(verified_request)

        hitch_mcp_dispatch!(verified_request)
      rescue VerifiedRequest::Failure => error
        hitch_mcp_protocol_error!(
          error.http_status,
          error.code,
          error.message,
          request_id: error.request_id,
          data: error.data
        )
      rescue StandardError
        request_id = verified_request && verified_request["id"]
        Internal::EndpointErrorReporter.report(category: :dispatch)
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

      def hitch_mcp_host_gate!
        hitch_mcp_append_vary!("Origin")
        if request.options?
          hitch_mcp_append_vary!("Access-Control-Request-Method")
          hitch_mcp_append_vary!("Access-Control-Request-Headers")
        end
        return if hitch_mcp_raw_host_allowed?

        head :bad_request
      end

      def hitch_mcp_origin_gate!
        origin = request.get_header("HTTP_ORIGIN")
        return hitch_mcp_origin_denied! if request.options? && origin.nil?
        return if origin.nil?
        return hitch_mcp_origin_denied! unless hitch_mcp_origin_allowed?(origin)
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
        raw_token = hitch_mcp_bearer_token
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

      def hitch_mcp_media_admitted!
        unless hitch_mcp_json_content_type?
          hitch_mcp_protocol_error!(415, -32600, "Invalid Request")
          return false
        end

        unless hitch_mcp_accepts_required_types?
          hitch_mcp_protocol_error!(406, -32600, "Invalid Request")
          return false
        end

        true
      end

      def hitch_mcp_dispatch!(verified_request)
        scope = hitch_mcp_resolve_scope
        context = hitch_mcp_context(verified_request, scope:)
        server_info = hitch_mcp_server_info(context)

        snapshot = Hitch.configuration.mcp.__send__(:registry_snapshot!)
        hitch_mcp_registry_resolved!
        tools = hitch_mcp_tools(verified_request:, context:, snapshot:)
        return if performed?

        hitch_mcp_sdk_dispatch_started!
        protocol_response = SDKAdapter.call(
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

      def hitch_mcp_server_info(context)
        callable = Hitch.configuration.mcp.server_info
        value = callable.call(context)
        raise ArgumentError, "mcp.server_info must return a Hash" unless value.is_a?(Hash)

        unknown = value.keys - SERVER_INFO_KEY_MAP.keys
        raise ArgumentError, "mcp.server_info contains unsupported keys" unless unknown.empty?

        canonical_keys = value.keys.map { |key| SERVER_INFO_KEY_MAP.fetch(key) }
        raise ArgumentError, "mcp.server_info contains duplicate keys" unless canonical_keys.uniq == canonical_keys

        normalized = value.to_h do |key, field|
          [ SERVER_INFO_KEY_MAP.fetch(key).dup.freeze, hitch_mcp_server_info_value(field) ]
        end
        %w[name version].each do |required|
          field = normalized[required]
          raise ArgumentError, "mcp.server_info requires name and version" unless field.is_a?(String) && !field.empty?
        end
        normalized.freeze
      end

      def hitch_mcp_server_info_value(value)
        raise ArgumentError, "mcp.server_info values must be strings" unless value.is_a?(String)

        value.dup.freeze
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

      def hitch_mcp_raw_host_allowed?
        resource = URI.parse(Hitch.configuration.resource_uri.to_s)
        hostname, explicit_port = hitch_mcp_parse_authority(request.get_header("HTTP_HOST"))
        resource_path = resource.path.empty? ? "/" : resource.path
        return false unless hostname
        return false unless request.get_header("rack.url_scheme") == resource.scheme
        return false unless request.get_header("PATH_INFO") == resource_path
        return false unless request.get_header("QUERY_STRING").to_s == resource.query.to_s

        default_port = resource.scheme == "https" ? 443 : 80
        effective_port = explicit_port || default_port
        return false unless effective_port == resource.port

        allowed_hosts = [ resource.hostname&.downcase, *Hitch.configuration.allowed_hosts ].compact.uniq
        allowed_hosts.include?(hostname)
      rescue URI::InvalidURIError
        false
      end

      def hitch_mcp_parse_authority(value)
        return [ nil, nil ] unless value.is_a?(String) && value.valid_encoding?
        return [ nil, nil ] if value.empty? || value.bytesize > 512
        return [ nil, nil ] if value.include?(",") || value.match?(/[\x00-\x20\x7F]/)

        match = if value.start_with?("[")
          /\A\[([0-9A-Fa-f:.]+)\](?::([0-9]{1,5}))?\z/.match(value)
        else
          /\A([^:\[\]]+)(?::([0-9]{1,5}))?\z/.match(value)
        end
        return [ nil, nil ] unless match

        port = match[2] && Integer(match[2], exception: false)
        return [ nil, nil ] if port && !port.between?(1, 65_535)

        [ match[1].downcase, port ]
      end

      def hitch_mcp_origin_allowed?(origin)
        return false unless origin.is_a?(String) && origin.valid_encoding?
        return false if origin.empty? || origin.include?(",") || HEADER_CONTROLS.match?(origin)
        return true if Hitch.configuration.allowed_origins.include?(origin)

        (Rails.env.development? || Rails.env.test?) && LOOPBACK_ORIGIN.match?(origin)
      end

      def hitch_mcp_origin_denied!
        response.headers.delete("Access-Control-Allow-Origin")
        head :forbidden
      end

      def hitch_mcp_preflight!
        method = hitch_mcp_single_header(request.get_header("HTTP_ACCESS_CONTROL_REQUEST_METHOD"))
        headers = hitch_mcp_requested_headers(request.get_header("HTTP_ACCESS_CONTROL_REQUEST_HEADERS"))
        return hitch_mcp_origin_denied! unless method == "POST" && headers

        allowed = ALLOWED_REQUEST_HEADERS.map(&:downcase)
        return hitch_mcp_origin_denied! unless headers.all? { |header| allowed.include?(header.downcase) }

        response.headers["Access-Control-Allow-Origin"] = request.get_header("HTTP_ORIGIN")
        response.headers["Access-Control-Allow-Methods"] = "POST"
        response.headers["Access-Control-Allow-Headers"] = ALLOWED_REQUEST_HEADERS.join(", ")
        response.headers["Access-Control-Max-Age"] = "600"
        head :no_content
      end

      def hitch_mcp_requested_headers(value)
        return [] if value.nil? || value.empty?
        return unless value.is_a?(String) && value.valid_encoding? && !HEADER_CONTROLS.match?(value)

        values = value.split(",", -1).map { |entry| hitch_mcp_trim_ows(entry) }
        values unless values.any? { |entry| entry.nil? || entry.empty? }
      end

      def hitch_mcp_json_content_type?
        value = request.get_header("CONTENT_TYPE")
        return false unless value.is_a?(String) && value.valid_encoding?
        return false if value.empty? || value.include?(",") || HEADER_CONTROLS.match?(value)

        media_type, *parameters = value.split(";", -1).map { |part| hitch_mcp_trim_ows(part) }
        return false unless media_type&.downcase == "application/json"

        parameters.all? { |parameter| parameter&.match?(/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+=[^;\s]+\z/) }
      end

      def hitch_mcp_accepts_required_types?
        value = request.get_header("HTTP_ACCEPT")
        return false unless value.is_a?(String) && value.valid_encoding?
        return false if value.empty? || HEADER_CONTROLS.match?(value)

        accepted = {}
        value.split(",", -1).each do |entry|
          media_type, quality = hitch_mcp_accept_entry(entry)
          return false unless media_type

          accepted[media_type] = true if ACCEPT_TYPES.include?(media_type) && quality.positive?
        end
        ACCEPT_TYPES.all? { |media_type| accepted[media_type] }
      end

      def hitch_mcp_accept_entry(entry)
        media_type, *parameters = entry.split(";", -1).map { |part| hitch_mcp_trim_ows(part) }
        return [ nil, nil ] unless media_type&.match?(/\A[A-Za-z0-9!#$%&'*+.^_`|~-]+\/[A-Za-z0-9!#$%&'*+.^_`|~-]+\z/)

        quality = 1.0
        quality_seen = false
        parameters.each do |parameter|
          name, raw_value = parameter.to_s.split("=", 2)
          return [ nil, nil ] unless name && raw_value
          next unless name.casecmp?("q")
          return [ nil, nil ] if quality_seen || !raw_value.match?(/\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/)

          quality_seen = true
          quality = raw_value.to_f
        end
        [ media_type.downcase, quality ]
      end

      def hitch_mcp_single_header(value)
        return unless value.is_a?(String) && value.valid_encoding?
        return if value.include?(",") || HEADER_CONTROLS.match?(value)

        candidate = hitch_mcp_trim_ows(value)
        candidate unless candidate.nil? || candidate.empty?
      end

      def hitch_mcp_trim_ows(value)
        value[/\A[\x20\x09]*(.*?)[\x20\x09]*\z/m, 1]
      end

      def hitch_mcp_bearer_token
        authorization = request.get_header("HTTP_AUTHORIZATION").to_s
        return if authorization.bytesize > MAX_BEARER_TOKEN_BYTES + 7
        return unless authorization.valid_encoding?
        return if authorization.match?(/[\u0000-\u001F\u007F-\u009F]/)

        match = authorization.match(/\ABearer ([A-Za-z0-9_-]{1,#{MAX_BEARER_TOKEN_BYTES}})\z/i)
        match && match[1]
      end

      def hitch_mcp_unauthorized!
        response.headers["WWW-Authenticate"] = hitch_mcp_bearer_challenge
        response.headers["Access-Control-Expose-Headers"] = "WWW-Authenticate"
        head :unauthorized
      end

      def hitch_mcp_insufficient_scope!(required_scopes)
        response.headers["WWW-Authenticate"] = "Bearer error=\"insufficient_scope\", " \
          "scope=\"#{required_scopes.join(' ')}\", " \
          "resource_metadata=\"#{hitch_mcp_resource_metadata_url}\""
        response.headers["Access-Control-Expose-Headers"] = "WWW-Authenticate"
        head :forbidden
      end

      def hitch_mcp_bearer_challenge
        # A generic 401 starts the least-privilege authorization flow with the
        # host's base/default scope. Protected-resource metadata still
        # advertises the complete supported set, and a known available tool
        # names its complete static requirement in a later 403 step-up.
        scope = Hitch.configuration.supported_scopes.first
        %(Bearer resource_metadata="#{hitch_mcp_resource_metadata_url}", scope="#{scope}")
      end

      def hitch_mcp_resource_metadata_url
        resource = URI.parse(Hitch.configuration.resource_uri.to_s)
        path = resource.path.to_s
        suffix = path.empty? || path == "/" ? "" : path
        query = resource.query ? "?#{resource.query}" : ""
        "#{issuer_url}/.well-known/oauth-protected-resource#{suffix}#{query}"
      end

      def hitch_mcp_append_vary!(value)
        values = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        values << value unless values.include?(value)
        response.headers["Vary"] = values.join(", ")
      end

      def hitch_mcp_tools(verified_request:, context:, snapshot:)
        if verified_request.fetch("method") == "tools/call"
          resolution = Registry.__send__(
            :runtime_call,
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

        Registry.__send__(:runtime_listing, snapshot:, context:)
      end

      # Private test seams wrap production-owned admission and request
      # observation; final Tool calls emit through Internal::Observation
      # directly.

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
          1,
          expires_in: configuration.request_limit.fetch(:within)
        )
      end

      def hitch_mcp_body_parse_started!; end
      def hitch_mcp_registry_resolved!; end
      def hitch_mcp_sdk_dispatch_started!; end
      def hitch_mcp_request_observed!
        @hitch_mcp_observation&.finish!(response:)
      end

      private_constant :MAX_BEARER_TOKEN_BYTES,
        :ALLOWED_REQUEST_HEADERS,
        :LOOPBACK_ORIGIN,
        :HEADER_CONTROLS,
        :ACCEPT_TYPES,
        :SERVER_INFO_KEY_MAP
    end
  end
end
