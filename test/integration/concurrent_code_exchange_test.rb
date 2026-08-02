# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"

class ConcurrentCodeExchangeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  RESOURCE = "https://example.test/mcp"

  setup do
    Hitch::AccessToken.delete_all
    User.delete_all
    Hitch.reset_configuration!
    Hitch.configure { |config| config.resource_uri = RESOURCE }
    @user = User.create!(email: "concurrent-exchange@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  teardown do
    Hitch::AccessToken.delete_all
    User.delete_all
  end

  test "simultaneous redemptions through independent connections mint exactly one token" do
    record = Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: "concurrent-client",
      client_name: "Concurrent",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    )
    code = record.raw_authorization_code
    ready = Queue.new
    start = Queue.new

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          Hitch::AccessToken.exchange_authorization_code!(
            raw_code: code,
            code_verifier: @verifier,
            client_id: "concurrent-client",
            resource_uri: RESOURCE
          )
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = workers.map(&:value)

    assert_equal 1, results.count(&:present?)
    assert_equal 1, results.count(&:nil?)
    winner = results.compact.fetch(0)
    assert_equal record.id, Hitch::AccessToken.find_by_token(winner.fetch(:raw_token)).id
    refute authorization_code_pending?(code)
    assert_nil Hitch::AccessToken.exchange_authorization_code!(
      raw_code: code,
      code_verifier: @verifier,
      client_id: "concurrent-client",
      resource_uri: RESOURCE
    )
  end
end
