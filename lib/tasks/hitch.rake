# frozen_string_literal: true

namespace :hitch do
  namespace :cimd do
    desc "Fetch a Client ID Metadata Document to verify this host's egress " \
         "(usage: bin/rails 'hitch:cimd:check[https://client.example/client.json]')"
    task :check, [ :client_id ] => :environment do |_task, args|
      client_id = args[:client_id]
      abort "Usage: bin/rails 'hitch:cimd:check[https://client.example/client.json]'" if client_id.blank?

      # Reports; never changes what discovery advertises. Whether this
      # host can reach one document today is a different question from
      # whether it supports CIMD, and only the second belongs in the
      # discovery document.
      result = Hitch::ClientIdMetadata.diagnose(client_id)

      puts "client_id: #{client_id}"
      puts "outcome:   #{result.outcome}"
      puts "detail:    #{result.detail}"
      puts
      puts(result.ok? ? "Egress to this document works." : "This host could not resolve that document.")
      exit(1) unless result.ok?
    end
  end
end
