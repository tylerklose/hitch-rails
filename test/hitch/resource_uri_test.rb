# frozen_string_literal: true

require "test_helper"

class Hitch::ResourceUriTest < ActiveSupport::TestCase
  test "canonicalizes scheme host and default port while preserving path and query" do
    assert_equal \
      "https://example.test/Mcp?tenant=One%20Two",
      Hitch::ResourceUri.canonicalize!("HTTPS://EXAMPLE.TEST:443/Mcp?tenant=One%20Two")
  end

  test "preserves a non-default port" do
    assert_equal \
      "https://example.test:8443/mcp",
      Hitch::ResourceUri.canonicalize!("https://EXAMPLE.TEST:8443/mcp")
  end

  test "rejects fragments including an empty fragment" do
    assert_raises(Hitch::ResourceUri::Invalid) do
      Hitch::ResourceUri.canonicalize!("https://example.test/mcp#")
    end
  end

  test "rejects userinfo" do
    assert_raises(Hitch::ResourceUri::Invalid) do
      Hitch::ResourceUri.canonicalize!("https://user:secret@example.test/mcp")
    end
  end

  test "allows plain HTTP only for an explicitly allowed loopback" do
    assert_equal \
      "http://127.0.0.1/mcp",
      Hitch::ResourceUri.canonicalize!("HTTP://127.0.0.1:80/mcp", allow_loopback_http: true)

    assert_raises(Hitch::ResourceUri::Invalid) do
      Hitch::ResourceUri.canonicalize!("http://127.0.0.1/mcp")
    end
    assert_raises(Hitch::ResourceUri::Invalid) do
      Hitch::ResourceUri.canonicalize!("http://example.test/mcp", allow_loopback_http: true)
    end
  end


  test "canonicalizes IPv6 loopback without double brackets" do
    assert_equal \
      "http://[::1]:3000/mcp",
      Hitch::ResourceUri.canonicalize!("http://[::1]:3000/mcp", allow_loopback_http: true)
  end
end
