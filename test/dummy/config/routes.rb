Rails.application.routes.draw do
  post "sign_in", to: "sign_ins#create"
  # A constrained host route proves Hitch's pre-routing form guard does not
  # claim a path the host owns before the root engine mount.
  post "*host_form_path", to: "host_forms#create", format: false,
    constraints: ->(request) do
      request.get_header("HTTP_X_HITCH_HOST_SHADOW") == "1" && request.path == "/oauth/./token"
    end
  post "oauth/token", to: "host_forms#create",
    constraints: ->(request) { request.get_header("HTTP_X_HITCH_HOST_SHADOW") == "1" }
  # Host-owned MCP endpoints that include Hitch::ServerEndpoint
  # (declared above the engine mount so they aren't shadowed by it).
  # mcp_test simulates the SDK return contract; real_mcp drives a genuine
  # ::MCP::Server through the concern.
  post "mcp_test", to: "mcp_test#create"
  post "real_mcp", to: "real_mcp#create"
  mount Hitch::Engine => "/"
end
