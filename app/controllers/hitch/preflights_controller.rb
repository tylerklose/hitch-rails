# frozen_string_literal: true

module Hitch
  # OPTIONS for the engine-owned auth and discovery routes. A request earns a
  # 204 only after its Host, Origin, target method, and requested headers pass.
  class PreflightsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport

    def show
      methods = request.path_parameters.fetch(:target_methods).split(",")
      hitch_preflight(allowed_methods: methods)
    end
  end
end
