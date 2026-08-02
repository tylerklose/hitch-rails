# frozen_string_literal: true

require "test_helper"
require "yaml"

class AuthorizationMetadataProfileTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://www.example.com/mcp"

  setup do
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = RESOURCE
      config.allowed_hosts = [ "www.example.com" ]
      config.dynamic_client_registration_enabled = true
      config.supported_scopes = [ "mcp" ]
    end
  end

  test "profile pins the official authorization-server runner sources" do
    profile = YAML.safe_load_file(File.expand_path("profile.yml", __dir__))
    upstream = profile.fetch("upstream")

    assert_equal "https://github.com/modelcontextprotocol/conformance", upstream.fetch("repository")
    assert_equal "0.2.0-alpha.10", upstream.fetch("version")
    assert_equal "a9896553900a2ef61787b57adfcbbe936a8ab1f9", upstream.fetch("commit")
    assert_equal "authorization-server-under-test", upstream.fetch("direction")
    assert_equal "authorization-server-metadata-endpoint",
      profile.fetch("official_profile").fetch("scenario")
    assert_equal "none", profile.fetch("official_profile").fetch("mutation")

    retention = profile.fetch("evidence_retention")
    assert_equal "ephemeral_never_uploaded", retention.fetch("credential_bearing_raw_output")
    assert_equal "sanitized_summary_and_raw_file_hashes", retention.fetch("ci_artifact")
    assert_equal "disposable_mode_0600_with_credential_canaries", retention.fetch("rails_log")
  end

  test "authorization and protected-resource metadata agree on the exact server contract" do
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    authorization = JSON.parse(response.body)

    assert_equal "https://www.example.com", authorization.fetch("issuer")
    assert_equal "https://www.example.com/oauth/authorize", authorization.fetch("authorization_endpoint")
    assert_equal "https://www.example.com/oauth/token", authorization.fetch("token_endpoint")
    assert_equal "https://www.example.com/oauth/register", authorization.fetch("registration_endpoint")
    assert_equal [ "authorization_code" ], authorization.fetch("grant_types_supported")
    assert_equal [ "code" ], authorization.fetch("response_types_supported")
    assert_equal [ "S256" ], authorization.fetch("code_challenge_methods_supported")
    assert_equal %w[none client_secret_basic], authorization.fetch("token_endpoint_auth_methods_supported")

    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :success
    protected_resource = JSON.parse(response.body)
    assert_equal RESOURCE, protected_resource.fetch("resource")
    assert_equal [ authorization.fetch("issuer") ], protected_resource.fetch("authorization_servers")
    assert_equal [ "header" ], protected_resource.fetch("bearer_methods_supported")
    assert_equal [ "mcp" ], protected_resource.fetch("scopes_supported")
  end
end
