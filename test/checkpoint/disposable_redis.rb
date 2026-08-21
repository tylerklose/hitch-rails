# frozen_string_literal: true

require "open3"
require "redis"
require "securerandom"
require "timeout"

module HitchCheckpoint
  # Disposable Redis used only by checkpoint acceptance: one plain container,
  # one loopback URL, gone when the block returns.
  class DisposableRedis
    IMAGE = "redis:7-alpine"
    READY_SECONDS = 20
    REDIS_DATABASE = 15

    def self.open
      service = new
      service.start!
      yield service
    ensure
      service&.stop!
    end

    attr_reader :url

    def start!
      @container_name = "hitch-checkpoint-redis-#{Process.pid}-#{SecureRandom.hex(4)}"
      run!(
        "docker", "run", "--detach", "--rm", "--name", @container_name,
        "--publish", "127.0.0.1::6379",
        IMAGE, "redis-server", "--save", "", "--appendonly", "no"
      )
      port = run!("docker", "port", @container_name, "6379/tcp")[/127\.0\.0\.1:(\d+)\s*\z/, 1]
      raise "could not resolve the disposable Redis loopback port" unless port

      @url = "redis://127.0.0.1:#{port}/#{REDIS_DATABASE}"
      wait_until_ready!
      self
    end

    def stop!
      return unless @container_name

      system("docker", "stop", "--time", "1", @container_name, out: File::NULL, err: File::NULL)
      @container_name = nil
      @url = nil
    end

    private

    def run!(*command)
      output, status = Open3.capture2e(*command)
      raise "command failed: #{command.first}\n#{output}" unless status.success?

      output
    end

    def wait_until_ready!
      client = Redis.new(url:, timeout: 0.25, connect_timeout: 0.25, reconnect_attempts: 0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_SECONDS
      begin
        client.ping
      rescue Redis::BaseError, RedisClient::Error, SystemCallError
        raise "disposable Redis did not become ready" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
        retry
      ensure
        client.close
      end
    end
  end
end
