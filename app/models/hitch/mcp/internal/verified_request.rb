# frozen_string_literal: true

require "json"

module Hitch
  module MCP
    module Internal
      # Builds the one immutable request value that may cross into the SDK.
      # HTTP media and body-size admission happen before this object sees bytes.
      class VerifiedRequest
        PROTOCOL_VERSION = "2026-07-28"
        SUPPORTED_METHODS = %w[server/discover tools/list tools/call].freeze
        OWS = /\A[\x20\x09]*(.*?)[\x20\x09]*\z/m
        HEADER_CONTROLS = /[\x00-\x08\x0A-\x1F\x7F]/
        CLIENT_INFO_KEY = "io.modelcontextprotocol/clientInfo"
        CLIENT_INFO_STRING_KEYS = %w[name version title description websiteUrl].freeze

        class Failure < StandardError
          attr_reader :http_status, :code, :request_id, :data

          def initialize(http_status:, code:, message:, request_id: nil, data: nil)
            @http_status = http_status
            @code = code
            @request_id = request_id
            @data = data
            super(message)
          end
        end

        class << self
          def call(raw_body:, headers:)
            new(raw_body, headers).call
          end
        end

        def initialize(raw_body, headers)
          @raw_body = raw_body
          @headers = headers
        end

        def call
          parsed = parse
          validate_json_values!(parsed)
          request_id = validate_envelope!(parsed)
          validate_metadata!(parsed, request_id)
          validate_protocol_and_method_headers!(parsed, request_id)
          validate_method!(parsed, request_id)
          validate_call_shape!(parsed, request_id)
          validate_name_header!(parsed, request_id)
          validate_reserved_arguments!(parsed, request_id)
          deep_copy_and_freeze(parsed)
        end

        private

        attr_reader :raw_body, :headers

        def parse
          source = raw_body.dup.force_encoding(Encoding::UTF_8)
          parse_error! unless source.valid_encoding?

          JSON.parse(source, allow_duplicate_key: false)
        rescue JSON::ParserError => error
          if error.message.include?("duplicate key")
            failure!(400, -32600, "Invalid Request")
          else
            parse_error!
          end
        rescue JSON::GeneratorError, JSON::NestingError
          parse_error!
        end

        def validate_json_values!(value)
          case value
          when Hash
            value.each do |key, child|
              parse_error! unless key.is_a?(String) && key.valid_encoding?

              validate_json_values!(child)
            end
          when Array
            value.each { |child| validate_json_values!(child) }
          when String
            parse_error! unless value.valid_encoding?
          when Float
            invalid_request! unless value.finite?
          end
        end

        def validate_envelope!(request)
          invalid_request! unless request.is_a?(Hash)
          invalid_request! unless request["jsonrpc"] == "2.0"
          invalid_request! unless request.key?("id")
          invalid_request! unless request["id"].is_a?(String) || request["id"].is_a?(Numeric)
          invalid_request! unless request["method"].is_a?(String)
          invalid_request! unless request["params"].is_a?(Hash)

          request.fetch("id")
        end

        def validate_metadata!(request, request_id)
          metadata = request.fetch("params")["_meta"]
          invalid_params!(request_id, 400) unless metadata.is_a?(Hash)

          version = metadata["io.modelcontextprotocol/protocolVersion"]
          capabilities = metadata["io.modelcontextprotocol/clientCapabilities"]
          invalid_params!(request_id, 400) unless version.is_a?(String)
          invalid_params!(request_id, 400) unless capabilities.is_a?(Hash)

          return unless metadata.key?(CLIENT_INFO_KEY)

          client_info = metadata[CLIENT_INFO_KEY]

          valid = client_info.is_a?(Hash) &&
            client_info["name"].is_a?(String) && !client_info["name"].empty? &&
            client_info["version"].is_a?(String) && !client_info["version"].empty? &&
            valid_client_info_strings?(client_info) &&
            valid_client_info_icons?(client_info)
          invalid_params!(request_id, 400) unless valid
        end

        def valid_client_info_strings?(client_info)
          CLIENT_INFO_STRING_KEYS.all? do |key|
            !client_info.key?(key) || client_info[key].is_a?(String)
          end
        end

        def valid_client_info_icons?(client_info)
          return true unless client_info.key?("icons")

          icons = client_info["icons"]
          icons.is_a?(Array) && icons.all? do |icon|
            icon.is_a?(Hash) &&
              icon["src"].is_a?(String) &&
              (!icon.key?("mimeType") || icon["mimeType"].is_a?(String)) &&
              (!icon.key?("sizes") || icon["sizes"].is_a?(Array) && icon["sizes"].all?(String))
          end
        end

        def validate_protocol_and_method_headers!(request, request_id)
          metadata = request.fetch("params").fetch("_meta")
          protocol_version = single_header(headers.fetch(:protocol_version, nil))
          method = single_header(headers.fetch(:method, nil))

          header_mismatch!(request_id) unless protocol_version == metadata.fetch("io.modelcontextprotocol/protocolVersion")
          header_mismatch!(request_id) unless method == request.fetch("method")

          return if protocol_version == PROTOCOL_VERSION

          failure!(
            400,
            -32022,
            "Unsupported protocol version",
            request_id: request_id,
            data: { "supportedVersions" => [ PROTOCOL_VERSION ] }
          )
        end

        def validate_method!(request, request_id)
          return if SUPPORTED_METHODS.include?(request.fetch("method"))

          failure!(404, -32601, "Method not found", request_id: request_id)
        end

        def validate_call_shape!(request, request_id)
          return unless request.fetch("method") == "tools/call"

          params = request.fetch("params")
          name = params["name"]
          arguments = params["arguments"]
          invalid_params!(request_id, 200) unless name.is_a?(String) && !name.empty?
          invalid_params!(request_id, 200) unless arguments.is_a?(Hash)
        end

        def validate_name_header!(request, request_id)
          supplied_name = headers.fetch(:name, nil)

          if request.fetch("method") == "tools/call"
            expected_name = request.fetch("params").fetch("name")
            header_mismatch!(request_id) unless single_header(supplied_name) == expected_name
          elsif !supplied_name.nil?
            header_mismatch!(request_id)
          end
        end

        def validate_reserved_arguments!(request, request_id)
          return unless request.fetch("method") == "tools/call"

          arguments = request.fetch("params").fetch("arguments")
          invalid_params!(request_id, 200) if arguments.key?("server_context")
        end

        def single_header(value)
          return unless value.is_a?(String) && value.valid_encoding?
          return if value.include?(",") || HEADER_CONTROLS.match?(value)

          match = OWS.match(value)
          candidate = match && match[1]
          candidate unless candidate.nil? || candidate.empty?
        end

        def parse_error!
          failure!(400, -32700, "Parse error")
        end

        def invalid_request!
          failure!(400, -32600, "Invalid Request")
        end

        def invalid_params!(request_id, http_status)
          failure!(http_status, -32602, "Invalid params", request_id: request_id)
        end

        def header_mismatch!(request_id)
          failure!(400, -32020, "HeaderMismatch", request_id: request_id)
        end

        def failure!(http_status, code, message, request_id: nil, data: nil)
          raise Failure.new(
            http_status: http_status,
            code: code,
            message: message,
            request_id: request_id,
            data: deep_copy_and_freeze(data)
          )
        end

        def deep_copy_and_freeze(value)
          copy = case value
          when Hash
            value.to_h { |key, child| [ key.to_s.dup.freeze, deep_copy_and_freeze(child) ] }
          when Array
            value.map { |child| deep_copy_and_freeze(child) }
          when String
            value.dup
          else
            value
          end
          copy.freeze
        end
      end
    end
  end
end
