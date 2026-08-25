# frozen_string_literal: true

require "uri"

module Hitch
  # What the /activate confirmation screen may honestly say about the client
  # behind a pending device grant.
  #
  # The device flow delivers nothing to a redirect_uri, so the consent
  # screen's verified signal — the host the authorization code is actually
  # sent to — does not survive the trip. What replaces it is a vouching
  # rule: a device grant is approvable only for a client somebody real
  # vouches for, and only the voucher's word is displayed. A CIMD client
  # is branded by its client_id's own URL host, earned by serving the
  # document there. A confidential client is branded by the name the
  # operator chose when they registered it at a console. A client that
  # only ever vouched for itself through open registration — even one DCR
  # issued a secret — is the §5.4 phishing shape: the mint endpoint refuses it, and this
  # object independently refuses to verify it, so the guarantee holds
  # whichever door a grant came through.
  #
  # CIMD resolution happens here, with the signed-in approver as the
  # rate-limit actor — never at the mint endpoint, which has no actor.
  class DeviceActivation
    include Hitch::UriValidation

    def initialize(grant, principal:)
      @grant = grant
      @principal = principal
    end

    attr_reader :grant

    # The live voucher must still exist and must agree with the immutable
    # authentication posture recorded at mint. That refuses both directions
    # of a registration race: a public/CIMD grant cannot borrow an operator
    # registration, and a confidential grant cannot fall back to CIMD after
    # its operator registration disappears.
    def unverified?
      case grant.token_endpoint_auth_method
      when "client_secret_basic" then !operator_registered?
      when "none" then document.nil?
      else true
      end
    end

    # A confidential client the operator registered at a console; its
    # display name is the operator's word, and the view says whose word
    # it is.
    def operator_registered?
      grant.token_endpoint_auth_method == "client_secret_basic" &&
        client&.operator_registered_confidential_client?
    end

    def display_client_name
      return client.client_name if operator_registered?

      # hostname, not host: URI#host keeps IPv6 brackets, which would
      # defeat a client_names entry keyed on the bare address.
      host = URI.parse(grant.client_id).hostname
      Hitch.configuration.client_label(host) || host
    end

    def audit_client_name
      document&.client_name || client&.client_name || "Unknown"
    end

    # The consent screen's own-computer warning, carried over: a client
    # whose every declared redirect is loopback http runs on the user's
    # machine, not at the host it displays as.
    def localhost_only_client?
      declared = document&.redirect_uris
      declared.present? && declared.all? { |uri| loopback_http_uri?(uri) }
    end

    def scopes
      @scopes ||= grant.scopes.to_s.split(/\s+/)
    end

    private

    # "none" is the posture of a CIMD-vouched grant. A registered row still
    # wins over URL shape, including one that appeared after mint; it cannot
    # lend the grant a different voucher than the one the polling client must
    # present at the token endpoint.
    def cimd_reference?
      return @cimd_reference if defined?(@cimd_reference)

      @cimd_reference = grant.token_endpoint_auth_method == "none" &&
        client.nil? && ClientIdMetadata.document_url?(grant.client_id)
    end

    # Only a CIMD-classified client resolves — a registered client must
    # never trigger a fetch however its id is shaped: its voucher is the
    # operator, and a remote document must not overwrite the operator's
    # word in the audit trail. Resolution also still honors the flag
    # (reference? consults it), so a switched-off scheme fetches nothing
    # and the client reads unverified.
    def document
      return @document if defined?(@document)

      @document = if cimd_reference? && ClientIdMetadata.reference?(grant.client_id)
        ClientIdMetadata.resolve(grant.client_id, actor: Hitch::RateLimitStore.actor_for(@principal))
      end
    end

    def client
      return @client if defined?(@client)

      @client = Client.find_by(client_id: grant.client_id)
    end
  end
end
