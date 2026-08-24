# frozen_string_literal: true

module Hitch
  # The device flow's feature gate, stated once: while the flag is off its
  # endpoints answer bare 404s — the registration posture. POSTs are refused
  # in admission via OauthFormAdmission's hook, before the body is read, so
  # no body-cap error names the feature; a GET calls the same method at the
  # top of its action. (The shared preflight and host checks still answer,
  # as they do for disabled registration — full indistinguishability is not
  # claimed.)
  module DeviceAuthorizationGate
    private

    def admit_oauth_endpoint!
      return true if Hitch.configuration.device_authorization_enabled

      head :not_found
      false
    end
  end
end
