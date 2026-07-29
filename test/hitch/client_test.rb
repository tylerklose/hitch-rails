# frozen_string_literal: true

require "test_helper"

class Hitch::ClientTest < ActiveSupport::TestCase
  setup { Hitch::Client.delete_all }

  test "register! persists a DCR record with normalized redirect_uris" do
    c = Hitch::Client.register!(
      client_id: "abc-123",
      client_name: "Claude Code",
      redirect_uris: [ "https://app.test/callback", nil, "", "https://other.test/cb" ]
    )
    assert_equal "abc-123", c.client_id
    assert_equal "Claude Code", c.client_name
    assert_equal [ "https://app.test/callback", "https://other.test/cb" ], c.redirect_uris
  end

  test "register! defaults client_name when caller sends blank" do
    c = Hitch::Client.register!(client_id: "x", client_name: "", redirect_uris: [])
    assert_equal "MCP Client", c.client_name
  end

  # MCP 2026-07-28 / RFC 7591 §2. Recorded, never enforced — the value is
  # what makes a later decision about loopback redirects evidence-based.
  test "register! persists a declared application_type" do
    Hitch::Client::APPLICATION_TYPES.each do |type|
      c = Hitch::Client.register!(
        client_id: "id-#{type}", client_name: "C", redirect_uris: [], application_type: type
      )
      assert_equal type, c.application_type
    end
  end

  # Absent and unrecognized are both "did not declare". Deliberately NOT
  # defaulted to "web" per RFC 7591 §2: that default would make a client
  # that genuinely said "web" indistinguishable from one that predates
  # the field, erasing exactly the signal the column exists to capture.
  test "register! records nil when application_type is absent or unrecognized" do
    [ nil, "", "desktop", "NATIVE", "web ", 42, [ "native" ] ].each_with_index do |value, i|
      c = Hitch::Client.register!(
        client_id: "junk-#{i}", client_name: "C", redirect_uris: [], application_type: value
      )
      assert_nil c.application_type, "#{value.inspect} should be recorded as no declaration"
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
    Hitch::Client.register!(client_id: "dup", client_name: "A", redirect_uris: [])
    assert_raises(ActiveRecord::RecordInvalid) do
      Hitch::Client.register!(client_id: "dup", client_name: "B", redirect_uris: [])
    end
  end
end
