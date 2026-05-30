Rails.application.routes.draw do
  post "sign_in", to: "sign_ins#create"
  # Host-owned MCP endpoints that include Hitch::ServerEndpoint
  # (declared above the engine mount so they aren't shadowed by it).
  # mcp_test simulates the SDK return contract; real_mcp drives a genuine
  # ::MCP::Server through the concern.
  post "mcp_test", to: "mcp_test#create"
  post "real_mcp", to: "real_mcp#create"
  mount Hitch::Engine => "/"
end
