# frozen_string_literal: true

module Hitch
  module Pkce
    S256_CHALLENGE = /\A[A-Za-z0-9_-]{43}\z/
    VERIFIER = /\A[A-Za-z0-9\-._~]{43,128}\z/

    module_function

    def valid_s256_challenge?(value)
      value.is_a?(String) && value.match?(S256_CHALLENGE)
    end

    def valid_verifier?(value)
      value.is_a?(String) && value.match?(VERIFIER)
    end
  end
end
