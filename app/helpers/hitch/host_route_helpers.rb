# frozen_string_literal: true

module Hitch
  # Hitch's pages render inside the host's layout, and a host nav says
  # root_path, not main_app.root_path (#43). A route helper the engine does
  # not define falls through to the host's. The engine's own helpers are
  # real methods, so they always win a name collision.
  module HostRouteHelpers
    def method_missing(name, ...)
      host_route_helper?(name) ? main_app.public_send(name, ...) : super
    end

    def respond_to_missing?(name, include_private = false)
      host_route_helper?(name) || super
    end

    private

    def host_route_helper?(name)
      name.end_with?("_path", "_url") && main_app.respond_to?(name)
    end
  end
end
