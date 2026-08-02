# frozen_string_literal: true

require "test_helper"

class Hitch::ClientConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Hitch::ClientRedirectUri.delete_all
    Hitch::Client.delete_all
  end

  teardown do
    Hitch::ClientRedirectUri.delete_all
    Hitch::Client.delete_all
  end

  test "concurrent rotations serialize and only the final secret remains valid" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "concurrent-rotation",
      client_name: "Concurrent Rotation",
      redirect_uris: [ "https://client.test/callback" ]
    )
    ready = Queue.new
    start = Queue.new

    workers = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          client = Hitch::Client.find(credentials.client.id)
          ready << true
          start.pop
          client.rotate_secret!.client_secret
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    rotated_secrets = workers.map(&:value)

    client = credentials.client.reload
    refute client.authenticates_secret?(credentials.client_secret)
    assert_equal 1, rotated_secrets.count { |secret| client.authenticates_secret?(secret) }
    assert client.client_secret_rotated_at.present?
  end
end
