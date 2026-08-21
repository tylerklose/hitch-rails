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

  test "authority omits a default port and brackets an IPv6 literal exactly once" do
    {
      "https://example.test/mcp" => "example.test",
      "https://example.test:443/mcp" => "example.test",
      "https://example.test:8443/mcp" => "example.test:8443",
      "http://127.0.0.1/mcp" => "127.0.0.1",
      "http://[::1]/mcp" => "[::1]",
      "http://[::1]:3000/mcp" => "[::1]:3000"
    }.each do |resource, expected|
      assert_equal expected, Hitch::ResourceUri.authority(URI.parse(resource)), resource
    end
  end

  test "origin is the scheme and authority with no path query or fragment" do
    {
      "https://example.test/mcp?tenant=one" => "https://example.test",
      "https://example.test:8443/mcp" => "https://example.test:8443",
      "http://[::1]:3000/mcp" => "http://[::1]:3000"
    }.each do |resource, expected|
      assert_equal expected, Hitch::ResourceUri.origin(URI.parse(resource)), resource
    end
  end

  # RFC 9728 §3.1: the well-known segment sits between the origin and the
  # resource's own path, and a resource query rides along unchanged.
  test "protected resource metadata url is path aware" do
    {
      "https://example.test/mcp" =>
        "https://example.test/.well-known/oauth-protected-resource/mcp",
      "https://example.test" =>
        "https://example.test/.well-known/oauth-protected-resource",
      "https://example.test/" =>
        "https://example.test/.well-known/oauth-protected-resource",
      "https://example.test:8443/mcp?tenant=one" =>
        "https://example.test:8443/.well-known/oauth-protected-resource/mcp?tenant=one",
      "http://[::1]:3000/mcp" =>
        "http://[::1]:3000/.well-known/oauth-protected-resource/mcp"
    }.each do |resource, expected|
      assert_equal \
        expected,
        Hitch::ResourceUri.protected_resource_metadata_url(URI.parse(resource)),
        resource
    end
  end
end
