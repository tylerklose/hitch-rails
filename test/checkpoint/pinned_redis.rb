# frozen_string_literal: true

require "open3"
require "rbconfig"
require "redis"
require "securerandom"
require "timeout"
require "yaml"

module HitchCheckpoint
  # Disposable, digest-pinned Redis used only by checkpoint acceptance. The
  # block owns the container: callers receive one loopback URL and cannot leave
  # the service running after the acceptance run returns or raises.
  class PinnedRedis
    LOCK_PATH = "test/conformance/toolchain.lock.yml"
    READY_SECONDS = 20
    COMMAND_TIMEOUT_SECONDS = 60
    REDIS_DATABASE = 15

    class CommandFailed < StandardError; end
    class CommandTimedOut < StandardError; end

    def self.open(root:)
      service = new(root:)
      service.start!
      yield service
    ensure
      primary_failure = $!
      begin
        service&.stop!
      rescue StandardError => cleanup_failure
        raise cleanup_failure unless primary_failure

        warn "Pinned Redis cleanup also failed: #{cleanup_failure.message}"
      end
    end

    def initialize(root:)
      @root = File.expand_path(root)
      lock = YAML.safe_load_file(File.join(@root, LOCK_PATH), permitted_classes: [], aliases: false)
      @redis_lock = lock.fetch("redis")
    end

    attr_reader :url

    def start!
      raise "pinned Redis is already running" if @container_name

      @platform, digest_key = locked_platform
      @image = @redis_lock.fetch("image")
      @index_digest = @redis_lock.fetch("index_digest")
      @platform_digest = @redis_lock.fetch(digest_key)
      repository = @image.sub(/:[^\/:]+\z/, "")
      @pinned_image = "#{repository}@#{@platform_digest}"
      @container_name = "hitch-checkpoint-redis-#{Process.pid}-#{SecureRandom.hex(4)}"

      resolve_pinned_image!
      @container_id = capture!(
        "docker", "run", "--detach", "--rm",
        "--name", @container_name,
        "--platform", @platform,
        "--publish", "127.0.0.1::6379",
        @pinned_image,
        "redis-server", "--save", "", "--appendonly", "no",
        timeout_seconds: COMMAND_TIMEOUT_SECONDS
      ).strip

      port_output = capture!(
        "docker", "port", @container_name, "6379/tcp",
        timeout_seconds: 30
      )
      port = port_output[/127\.0\.0\.1:(\d+)\s*\z/, 1]
      raise "could not resolve the pinned Redis loopback port" unless port

      @url = "redis://127.0.0.1:#{port}/#{REDIS_DATABASE}"
      @redis = Redis.new(url:, timeout: 0.25, connect_timeout: 0.25, reconnect_attempts: 0)
      wait_until_ready!
      @server_version = @redis.info("server").fetch("redis_version")
      self
    end

    def evidence
      raise "pinned Redis has not started" unless @server_version

      {
        "image" => @image,
        "index_digest" => @index_digest,
        "platform" => @platform,
        "platform_digest" => @platform_digest,
        "resolved_reference" => @pinned_image,
        "resolution" => @image_resolution,
        "server_version" => @server_version,
        "gem_requirement" => @redis_lock.fetch("gem_requirement"),
        "gem_version" => Redis::VERSION,
        "database" => REDIS_DATABASE,
        "network" => "ephemeral_loopback_port",
        "persistence" => "disabled"
      }.freeze
    end

    def stop!
      container_cleanup_complete = @container_name.nil?
      close_failure = begin
        @redis&.close
        nil
      rescue StandardError => error
        error
      end

      if @container_name
        if container_exists?
          begin
            capture!(
              "docker", "stop", "--time", "1", @container_name,
              timeout_seconds: 15
            )
          rescue CommandFailed, CommandTimedOut
            capture!(
              "docker", "rm", "--force", @container_name,
              timeout_seconds: 15
            )
          end
        end
        raise "pinned Redis container survived cleanup" if container_exists?

        container_cleanup_complete = true
      end
      raise close_failure if close_failure
    ensure
      @redis = nil
      @url = nil
      if container_cleanup_complete
        @container_id = nil
        @container_name = nil
      end
    end

    private

    def locked_platform
      architecture = RbConfig::CONFIG.fetch("host_cpu")
      case architecture
      when /arm64|aarch64/ then [ "linux/arm64", "linux_arm64_digest" ]
      when /x86_64|amd64/ then [ "linux/amd64", "linux_amd64_digest" ]
      else
        raise "unsupported Docker architecture for pinned Redis: #{architecture}"
      end
    end

    def resolve_pinned_image!
      if local_pinned_image_matches_platform?
        @image_resolution = "verified_local_digest"
        return
      end

      capture!(
        "docker", "pull", "--platform", @platform, @pinned_image,
        timeout_seconds: 300
      )
      unless local_pinned_image_matches_platform?
        raise "pinned Redis image does not match locked platform #{@platform}"
      end

      @image_resolution = "pulled_exact_digest"
    end

    def local_pinned_image_matches_platform?
      capture!(
        "docker", "image", "inspect", "--format", "{{.Os}}/{{.Architecture}}", @pinned_image,
        timeout_seconds: 15
      ).strip == @platform
    rescue CommandFailed
      false
    end

    def wait_until_ready!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_SECONDS
      loop do
        return if @redis.ping == "PONG"
      rescue Redis::BaseError, RedisClient::Error, SystemCallError
        raise "pinned Redis did not become ready" if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
    end

    def container_exists?
      output = capture!(
        "docker", "container", "ls", "--all", "--quiet",
        "--filter", "name=^/#{@container_name}$",
        timeout_seconds: 15
      )
      !output.lines.map(&:strip).reject(&:empty?).empty?
    end

    def capture!(*command, timeout_seconds:)
      output = +""
      status = nil
      Open3.popen2e(*command, pgroup: true) do |stdin, io, wait_thread|
        stdin.close
        reader = Thread.new { io.each { |chunk| output << chunk } }
        begin
          status = Timeout.timeout(timeout_seconds) { wait_thread.value }
        rescue Timeout::Error
          terminate(wait_thread)
          raise CommandTimedOut, "command timed out: #{command.first}"
        ensure
          reader.join
        end
      end
      raise CommandFailed, "command failed: #{command.first}\n#{output}" unless status.success?

      output
    end

    def terminate(wait_thread)
      signal_process_group("TERM", wait_thread.pid)
      begin
        Timeout.timeout(5) { wait_thread.value }
      rescue Timeout::Error
        signal_process_group("KILL", wait_thread.pid)
        wait_thread.value
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    def signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    private_constant :CommandFailed, :CommandTimedOut
  end
end
