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

  test "client_id uniqueness enforced" do
    Hitch::Client.register!(client_id: "dup", client_name: "A", redirect_uris: [])
    assert_raises(ActiveRecord::RecordInvalid) do
      Hitch::Client.register!(client_id: "dup", client_name: "B", redirect_uris: [])
    end
  end
end
