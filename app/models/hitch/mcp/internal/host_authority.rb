# frozen_string_literal: true

require "uri"

module Hitch
  module MCP
    module Internal
      # Exact binding of an incoming request to the canonical resource URI:
      # scheme, path, query, effective port, and an allowlisted Host header
      # parsed strictly (no lists, no controls, bounded length).
      module HostAuthority
        module_function

        def allowed?(request)
          resource = URI.parse(Hitch.configuration.resource_uri.to_s)
          hostname, explicit_port = parse_authority(request.get_header("HTTP_HOST"))
          resource_path = resource.path.empty? ? "/" : resource.path
          return false unless hostname
          return false unless request.get_header("rack.url_scheme") == resource.scheme
          return false unless request.get_header("PATH_INFO") == resource_path
          return false unless request.get_header("QUERY_STRING").to_s == resource.query.to_s

          return false unless (explicit_port || resource.default_port) == resource.port

          allowed_hosts = [ resource.hostname&.downcase, *Hitch.configuration.allowed_hosts ].compact.uniq
          allowed_hosts.include?(hostname)
        rescue URI::InvalidURIError
          false
        end

        def parse_authority(value)
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
      end
    end
  end
end
