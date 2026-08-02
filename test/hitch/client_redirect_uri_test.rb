# frozen_string_literal: true

require "test_helper"

class Hitch::ClientRedirectUriTest < ActiveSupport::TestCase
  setup do
    Hitch::Client.delete_all
    Hitch::SchemaState.find_or_create_by!(key: Hitch::SchemaState::REDIRECT_URIS_KEY) do |state|
      state.version = 2
    end.update!(version: 2)
  end

  test "state 2 reads sorted normalized redirects and replacement removes stale rows" do
    assert_raises(Hitch::Client::InvalidRegistrationMetadata) do
      Hitch::Client.register!(
        client_id: "lossy-client",
        client_name: "Lossy",
        redirect_uris: [ "https://z.example/callback", "https://z.example/callback", "" ]
      )
    end

    client = Hitch::Client.register!(
      client_id: "sorted-client",
      client_name: "Sorted",
      redirect_uris: [
        "https://z.example/callback",
        "https://a.example/callback"
      ]
    )

    assert_equal(
      [ "https://a.example/callback", "https://z.example/callback" ],
      client.redirect_uris
    )

    client.redirect_uris = [ "https://m.example/callback" ]

    assert_equal [ "https://m.example/callback" ], client.reload.redirect_uris
    assert_equal 1, client.redirect_uri_records.count
  end

  test "compatibility writes keep the legacy array and normalized rows in parity" do
    unless Hitch::Client.connection.column_exists?(:hitch_clients, :redirect_uris)
      assert_equal 2, Hitch::SchemaState.redirect_uris_version
      assert_raises(Hitch::SchemaState::CorruptState) do
        Hitch::SchemaState.find_by!(key: Hitch::SchemaState::REDIRECT_URIS_KEY).update_column(:version, 1)
        Hitch::Client.register!(
          client_id: "impossible-legacy",
          client_name: "Impossible",
          redirect_uris: [ "https://client.example/callback" ]
        )
      end
      next
    end

    Hitch::SchemaState.find_by!(key: Hitch::SchemaState::REDIRECT_URIS_KEY).update!(version: 1)
    client = Hitch::Client.register!(
      client_id: "dual-client",
      client_name: "Dual",
      redirect_uris: [ "https://b.example/callback", "https://a.example/callback" ]
    )

    assert_equal(
      [ "https://b.example/callback", "https://a.example/callback" ],
      client[:redirect_uris]
    )
    assert_equal(
      [ "https://a.example/callback", "https://b.example/callback" ],
      client.redirect_uri_records.order(:uri).pluck(:uri)
    )
  end

  test "database uniqueness is final and deleting a client cascades without callbacks" do
    client = Hitch::Client.register!(
      client_id: "cascade-client",
      client_name: "Cascade",
      redirect_uris: [ "https://client.example/callback" ]
    )
    uri = client.redirect_uri_records.first

    duplicate = client.redirect_uri_records.build(uri: uri.uri)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:uri], "has already been taken"

    assert_difference(-> { Hitch::ClientRedirectUri.count }, -1) do
      Hitch::Client.where(id: client.id).delete_all
    end
  end

  test "missing authority state fails reads and writes closed" do
    client = Hitch::Client.register!(
      client_id: "closed-client",
      client_name: "Closed",
      redirect_uris: [ "https://client.example/callback" ]
    )
    Hitch::SchemaState.where(key: Hitch::SchemaState::REDIRECT_URIS_KEY).delete_all

    assert_raises(Hitch::SchemaState::CorruptState) { client.redirect_uris }
    assert_raises(Hitch::SchemaState::CorruptState) do
      client.redirect_uris = [ "https://changed.example/callback" ]
    end
    assert_equal [ "https://client.example/callback" ], client.redirect_uri_records.pluck(:uri)
  end

  test "authority state is read uncached from the writing database" do
    state = Hitch::SchemaState.find_by!(key: Hitch::SchemaState::REDIRECT_URIS_KEY)

    assert_equal 2, Hitch::SchemaState.redirect_uris_version
    state.update_column(:version, 1)
    assert_equal 1, Hitch::SchemaState.redirect_uris_version
    state.update_column(:version, 2)
    assert_equal 2, Hitch::SchemaState.redirect_uris_version
  end
end
