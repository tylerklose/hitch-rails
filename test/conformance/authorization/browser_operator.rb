#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "nokogiri"
require "openssl"
require "optparse"
require "time"
require "uri"

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: browser_operator.rb --issuer URI --user-id ID --resource URI --redirect-uri URI [--ca-file PATH]"
  parser.on("--issuer URI") { |value| options[:issuer] = URI(value) }
  parser.on("--user-id ID") { |value| options[:user_id] = value }
  parser.on("--resource URI") { |value| options[:resource] = value }
  parser.on("--redirect-uri URI") { |value| options[:redirect_uri] = URI(value) }
  parser.on("--ca-file PATH") { |value| options[:ca_file] = value }
end.parse!

required = %i[issuer user_id resource redirect_uri]
missing = required.reject { |name| options[name] }
abort "Missing options: #{missing.join(", ")}" if missing.any?

authorization_url = $stdin.gets&.strip
abort "Read no authorization URL from stdin" if authorization_url.to_s.empty?
authorization_uri = URI(authorization_url)
abort "Authorization URL is outside the fixture issuer" unless
  authorization_uri.scheme == options[:issuer].scheme &&
    authorization_uri.host == options[:issuer].host &&
    authorization_uri.port == options[:issuer].port

def request(uri, request, ca_file: nil)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  if http.use_ssl?
    store = OpenSSL::X509::Store.new
    store.set_default_paths
    store.add_file(ca_file) if ca_file
    http.cert_store = store
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  end
  http.start { http.request(request) }
end

def merge_response_cookies(cookies, response)
  response.get_fields("set-cookie").to_a.each do |value|
    pair = value.split(";", 2).first
    name, = pair.split("=", 2)
    cookies[name] = pair
  end
  cookies
end

sign_in_uri = options[:issuer].dup
sign_in_uri.path = "/sign_in"
sign_in_uri.query = nil
sign_in = Net::HTTP::Post.new(sign_in_uri)
sign_in["Content-Type"] = "application/x-www-form-urlencoded"
sign_in.body = URI.encode_www_form(user_id: options[:user_id])
sign_in_response = request(sign_in_uri, sign_in, ca_file: options[:ca_file])
abort "Fixture sign-in failed" unless sign_in_response.code == "200"

cookies = merge_response_cookies({}, sign_in_response)
abort "Fixture sign-in returned no session cookie" if cookies.empty?
cookie_header = cookies.values.join("; ")

consent = Net::HTTP::Get.new(authorization_uri)
consent["Cookie"] = cookie_header
consent_response = request(authorization_uri, consent, ca_file: options[:ca_file])
abort "Consent screen failed" unless consent_response.code == "200"
merge_response_cookies(cookies, consent_response)
cookie_header = cookies.values.join("; ")

document = Nokogiri::HTML5(consent_response.body)
form = document.at_css("form[action$='/oauth/authorize']")
abort "Consent screen did not contain the authorization form" unless form

pairs = form.css("input[name]").filter_map do |input|
  next if input["disabled"]

  [ input["name"], input["value"].to_s ]
end
submitted = pairs.to_h
abort "Consent resource did not match the runner request" unless submitted["resource"] == options[:resource]
abort "Consent redirect did not match the fixture callback" unless submitted["redirect_uri"] == options[:redirect_uri].to_s
abort "Consent form did not carry a CSRF token" if submitted["authenticity_token"].to_s.empty?

approval_uri = options[:issuer].dup
approval_uri.path = form["action"]
approval_uri.query = nil
approval = Net::HTTP::Post.new(approval_uri)
approval["Content-Type"] = "application/x-www-form-urlencoded"
approval["Cookie"] = cookie_header
approval.body = URI.encode_www_form(pairs)
approval_response = request(approval_uri, approval, ca_file: options[:ca_file])
abort "Consent approval did not redirect (HTTP #{approval_response.code})" unless
  approval_response.is_a?(Net::HTTPRedirection)

callback_uri = URI(approval_response["Location"])
expected = options[:redirect_uri]
abort "Consent redirected outside the fixture callback" unless
  callback_uri.scheme == expected.scheme && callback_uri.host == expected.host &&
    callback_uri.port == expected.port && callback_uri.path == expected.path

callback_values = URI.decode_www_form(callback_uri.query.to_s).to_h
abort "Authorization response omitted its code" if callback_values["code"].to_s.empty?
abort "Authorization response state did not round-trip" unless callback_values["state"] == submitted["state"]

# Deliberately omit the host session cookie when delivering the code to the
# runner. Neither credential-shaped query values nor response bodies are logged.
callback_response = request(callback_uri, Net::HTTP::Get.new(callback_uri), ca_file: options[:ca_file])
abort "Runner callback rejected the authorization response" unless callback_response.is_a?(Net::HTTPSuccess)

puts JSON.pretty_generate(
  schema: "hitch.conformance.operator-attestation.v1",
  recorded_at: Time.now.utc.iso8601,
  issuer: options[:issuer].to_s,
  resource: options[:resource],
  redirect_origin: "#{expected.scheme}://#{expected.host}:#{expected.port}",
  consent_html_verified: true,
  csrf_present: true,
  approval: "approved",
  callback_delivered: true,
  credential_values_in_operator_output: false
)
