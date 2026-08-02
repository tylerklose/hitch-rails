# frozen_string_literal: true

module Hitch
  module OauthParameterValidation
    extend ActiveSupport::Concern

    included do
      rescue_from Hitch::OauthRequestParameters::Invalid, with: :render_oauth_parameter_error
    end

    private

    def oauth_parameters(*allowed, form_only: false)
      Hitch::OauthRequestParameters.new(request, allowed: allowed, form_only: form_only).to_h
    end

    def render_oauth_parameter_error(error)
      oauth_error("invalid_request", error.message)
    end
  end
end
