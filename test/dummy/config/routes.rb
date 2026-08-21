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
  match "mcp", to: "mcp#handle", via: :all
  mount Hitch::Engine => "/"
end
