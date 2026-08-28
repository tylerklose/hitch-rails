# frozen_string_literal: true

require "test_helper"

class Hitch::ClientTest < ActiveSupport::TestCase
  setup do
    Hitch::ClientRedirectUri.delete_all
    Hitch::Client.delete_all
  end

  test "register! rejects lossy redirect normalization and persists an exact valid array" do
    assert_raises(Hitch::Client::InvalidRegistrationMetadata) do
      Hitch::Client.register!(
        client_id: "lossy",
        client_name: "Claude Code",
        redirect_uris: [ "https://app.test/callback", nil, "" ]
      )
    end

    c = Hitch::Client.register!(client_id: "abc-123", client_name: "Claude Code",
      redirect_uris: [ "https://app.test/callback", "https://other.test/cb" ])
    assert_equal "abc-123", c.client_id
    assert_equal "Claude Code", c.client_name
    assert_equal [ "https://app.test/callback", "https://other.test/cb" ], c.redirect_uris
  end

  test "register! defaults an absent client_name but rejects a supplied blank" do
    c = Hitch::Client.register!(client_id: "x", client_name: nil,
      redirect_uris: [ "https://app.test/callback" ])
    assert_equal "MCP Client", c.client_name

    assert_raises(Hitch::Client::InvalidRegistrationMetadata) do
      Hitch::Client.register!(client_id: "blank", client_name: "",
        redirect_uris: [ "https://app.test/callback" ])
    end
  end

  # MCP 2026-07-28 / OpenID Connect Dynamic Client Registration 1.0 §2.
  # Recorded, never enforced — the value is
  # what makes a later decision about loopback redirects evidence-based.
  test "register! persists a declared application_type" do
    Hitch::Client::APPLICATION_TYPES.each do |type|
      c = Hitch::Client.register!(
        client_id: "id-#{type}", client_name: "C",
        redirect_uris: [ "https://app.test/#{type}" ], application_type: type
      )
      assert_equal type, c.application_type
    end
  end

  # Absent and unrecognized are both "did not declare". Deliberately NOT
  # defaulted to "web" per OpenID Connect Dynamic Client Registration
  # 1.0 §2: that default would make a client
  # that genuinely said "web" indistinguishable from one that predates
  # the field, erasing exactly the signal the column exists to capture.
  test "register! records nil when application_type is absent or unrecognized" do
    [ nil, "", "desktop", "NATIVE", "web " ].each_with_index do |value, i|
      c = Hitch::Client.register!(
        client_id: "junk-#{i}", client_name: "C",
        redirect_uris: [ "https://app.test/#{i}" ], application_type: value
      )
      assert_nil c.application_type, "#{value.inspect} should be recorded as no declaration"
    end


    [ 42, [ "native" ] ].each do |value|
      assert_raises(Hitch::Client::InvalidRegistrationMetadata) do
        Hitch::Client.register!(client_id: "typed-#{value.class}", client_name: "C",
          redirect_uris: [ "https://app.test/callback" ], application_type: value)
      end
    end
  end

  # A junk value must not cost the client its registration — the server
  # does not act on the field, so rejecting over it would break a client
  # for nothing.
  test "an unrecognized application_type does not reject the registration" do
    c = Hitch::Client.register!(
      client_id: "still-ok", client_name: "C", redirect_uris: [ "https://a.test/cb" ],
      application_type: "nonsense"
    )
    assert c.persisted?
    assert_equal [ "https://a.test/cb" ], c.redirect_uris
  end

  test "client_id uniqueness enforced" do
    Hitch::Client.register!(client_id: "dup", client_name: "A",
      redirect_uris: [ "https://app.test/a" ])
    assert_raises(ActiveRecord::RecordInvalid) do
      Hitch::Client.register!(client_id: "dup", client_name: "B",
        redirect_uris: [ "https://app.test/b" ])
    end
  end

  test "register_confidential! returns a secret once and persists only its digest" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "deploy-bot",
      client_name: "Deploy Bot",
      redirect_uris: [ "https://client.test/callback" ]
    )

    refute credentials.client.operator_registered?
    client = credentials.client

    assert client.confidential_client?
    assert credentials.client_secret.present?
    refute_equal credentials.client_secret, client.client_secret_digest
    assert client.authenticates_secret?(credentials.client_secret)
    refute client.authenticates_secret?("wrong-secret")
    refute_includes client.attributes.values, credentials.client_secret
  end

  test "rotate_secret! invalidates the previous confidential secret" do
    original = Hitch::Client.register_confidential!(
      client_id: "rotating",
      client_name: "Rotating",
      redirect_uris: [ "https://client.test/callback" ]
    )
    rotated = original.client.rotate_secret!

    refute original.client.authenticates_secret?(original.client_secret)
    assert original.client.authenticates_secret?(rotated.client_secret)
    assert original.client.client_secret_rotated_at.present?
  end

  test "public clients cannot rotate a nonexistent secret" do
    client = Hitch::Client.register!(client_id: "public", client_name: "Public",
      redirect_uris: [ "https://app.test/callback" ])

    assert_raises(ArgumentError) { client.rotate_secret! }
  end

  test "operator_registered requires a confidential client" do
    client = Hitch::Client.register!(
      client_id: "public-operator",
      client_name: "Public",
      redirect_uris: [ "https://app.test/callback" ]
    )
    client.operator_registered = true
    refute_predicate client, :valid?
    assert_includes client.errors[:operator_registered], "requires a confidential client"

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Hitch::Client.transaction(requires_new: true) do
        client.update_column(:operator_registered, true)
      end
    end
    assert_match(/hitch_clients_operator_registration_check/, error.message)
  end
end
