# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

# Regression guards for consent-flow fixes found by driving a real Grok
# connector against a from-scratch Rails 8 app (the hitch-canary). Each
# was invisible to the unit suite but broke the live OAuth flow.
class ConsentFlowTest < ActionDispatch::IntegrationTest
  REDIRECT = "https://claude.ai/callback"
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE
      c.brand_name = "Dummy"
    end
    @user = User.create!(email: "consent@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  def register_client
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ REDIRECT ] }
    assert_response :created
    JSON.parse(response.body)["client_id"]
  end

  # The consent Approve form redirects to the client's redirect_uri — a
  # cross-origin host. Turbo Drive submits via fetch and CANNOT follow a
  # cross-origin 302, so a default form_with makes "Approve" silently do
  # nothing. The form must opt out of Turbo for a real browser navigation.
  test "consent form opts out of Turbo so cross-origin redirect works" do
    client_id = register_client
    sign_in @user

    get "/oauth/authorize", params: {
      client_id: client_id, redirect_uri: REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE
    }
    assert_response :success
    assert_match(/data-turbo="false"/, response.body,
      "consent form must set data-turbo=false or Approve can't follow the cross-origin redirect")
  end

  # On an unauthenticated consent hit, the gem must remember where the user
  # was headed so the host's auth flow returns them to consent after login
  # (Rails 8 reads session[:return_to_after_authenticating]). Without it,
  # post-login dumps the user at root and strands the OAuth flow.
  test "unauthenticated consent stores the return-to location for the host login" do
    client_id = register_client
    # no sign_in → current_principal nil → require_principal!

    get "/oauth/authorize", params: {
      client_id: client_id, redirect_uri: REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256"
    }

    saved = session[:return_to_after_authenticating]
    assert saved.present?, "consent GET must save a return-to location for login"
    assert_includes saved, "/oauth/authorize",
      "saved return-to must point back at the consent screen"
    assert_includes saved, "client_id=#{client_id}",
      "saved return-to must preserve the OAuth params"
  end
end
