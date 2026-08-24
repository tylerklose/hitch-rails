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
  # only ever vouched for itself — open registration's public clients —
  # is the §5.4 phishing shape: the mint endpoint refuses it, and this
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

    # A client with no live voucher right now: a CIMD reference whose
    # document does not resolve (or whose scheme has been switched off
    # since mint), a registered client deleted while its grant was pending
    # — deletion is the operator's revoke gesture, and this is where the
    # pending grant meets it — or a self-registered public client, which
    # never had a voucher at all. The screen says so and offers no
    # Approve. The grant is left pending, not denied: none of these says
    # anything about the person's intent, and it expires on its own.
    def unverified?
      cimd_reference? ? document.nil? : !client&.confidential_client?
    end

    # A confidential client the operator registered at a console; its
    # display name is the operator's word, and the view says whose word
    # it is.
    def operator_registered?
      !cimd_reference?
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

    # A registered row wins over shape: operators may create clients with
    # URL-shaped ids while CIMD is off, and those must not read as forever-
    # unresolvable documents. No attacker reaches this arm — registration
    # generates its own opaque ids, so no anonymous client carries a chosen
    # URL. Past that, shape decides, not the live flag: disabling CIMD
    # mid-grant must not reclassify a metadata client as
    # approvable-but-anonymous.
    def cimd_reference?
      return @cimd_reference if defined?(@cimd_reference)

      @cimd_reference = client.nil? && ClientIdMetadata.document_url?(grant.client_id)
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
