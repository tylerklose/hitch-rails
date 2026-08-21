# frozen_string_literal: true

require "test_helper"

class Hitch::ClientRedirectUriTest < ActiveSupport::TestCase
  setup do
    Hitch::Client.delete_all
  end

  test "reads are sorted normalized redirects and replacement removes stale rows" do
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

  test "the writer works on unpersisted records through the association" do
    client = Hitch::Client.new(
      client_id: "new-record-writer",
      client_name: "New",
      token_endpoint_auth_method: "none",
      redirect_uris: [ "https://b.example/cb", "https://a.example/cb" ]
    )
    client.save!

    assert_equal [ "https://a.example/cb", "https://b.example/cb" ], client.reload.redirect_uris
  end

  test "the writer validates shape before touching any rows" do
    client = Hitch::Client.register!(
      client_id: "strict-writer",
      client_name: "Strict",
      redirect_uris: [ "https://keep.example/cb" ]
    )

    assert_raises(Hitch::Client::InvalidRegistrationMetadata) do
      client.redirect_uris = [ "https://ok.example/cb", "" ]
    end
    assert_equal [ "https://keep.example/cb" ], client.reload.redirect_uris
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
end
