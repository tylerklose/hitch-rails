# frozen_string_literal: true

require "test_helper"
require_relative "pinned_redis"

class HitchCheckpoint::PinnedRedisTest < ActiveSupport::TestCase
  PLATFORM = "linux/arm64"
  PINNED_IMAGE = "docker.io/library/redis@sha256:#{'a' * 64}"

  test "uses an exact locally cached platform digest without a network pull" do
    service = build_service
    commands = []
    service.define_singleton_method(:capture!) do |*command, timeout_seconds:|
      commands << [ command, timeout_seconds ]
      "linux/arm64\n"
    end

    service.__send__(:resolve_pinned_image!)

    assert_equal "verified_local_digest", service.instance_variable_get(:@image_resolution)
    assert_equal 1, commands.length
    assert_equal [ "docker", "image", "inspect" ], commands.first.first.first(3)
  end

  test "pulls the exact digest when the cached image has the wrong platform" do
    service = build_service
    commands = []
    inspections = 0
    service.define_singleton_method(:capture!) do |*command, timeout_seconds:|
      commands << [ command, timeout_seconds ]
      if command.first(3) == [ "docker", "image", "inspect" ]
        inspections += 1
        inspections == 1 ? "linux/amd64\n" : "linux/arm64\n"
      else
        "pulled\n"
      end
    end

    service.__send__(:resolve_pinned_image!)

    assert_equal "pulled_exact_digest", service.instance_variable_get(:@image_resolution)
    pull = commands.find { |command, _timeout| command.first(2) == [ "docker", "pull" ] }
    assert_equal [ "docker", "pull", "--platform", PLATFORM, PINNED_IMAGE ], pull.first
    assert_equal 300, pull.last
  end

  test "fails closed when a pull does not resolve the locked platform" do
    service = build_service
    service.define_singleton_method(:capture!) do |*command, timeout_seconds:|
      command.first(3) == [ "docker", "image", "inspect" ] ? "linux/amd64\n" : "pulled\n"
    end

    error = assert_raises(RuntimeError) { service.__send__(:resolve_pinned_image!) }
    assert_equal "pinned Redis image does not match locked platform #{PLATFORM}", error.message
  end

  test "cleanup fails closed when Docker cannot confirm container absence" do
    service = build_running_service
    service.define_singleton_method(:capture!) do |*command, timeout_seconds:|
      raise "Docker daemon unavailable" if command.first(3) == [ "docker", "container", "ls" ]
    end

    error = assert_raises(RuntimeError) { service.stop! }

    assert_equal "Docker daemon unavailable", error.message
    assert_equal "hitch-checkpoint-redis-test", service.instance_variable_get(:@container_name)
    assert_nil service.url
  end

  test "cleanup stops the container and confirms absence before clearing its identity" do
    service = build_running_service
    commands = []
    inspections = 0
    service.define_singleton_method(:capture!) do |*command, timeout_seconds:|
      commands << [ command, timeout_seconds ]
      if command.first(3) == [ "docker", "container", "ls" ]
        inspections += 1
        inspections == 1 ? "container-id\n" : ""
      else
        "container-id\n"
      end
    end

    service.stop!

    assert_equal 2, inspections
    assert commands.any? { |command, _timeout| command.first(2) == [ "docker", "stop" ] }
    assert_nil service.instance_variable_get(:@container_name)
    assert_nil service.instance_variable_get(:@container_id)
  end

  private

  def build_service
    HitchCheckpoint::PinnedRedis.allocate.tap do |service|
      service.instance_variable_set(:@platform, PLATFORM)
      service.instance_variable_set(:@pinned_image, PINNED_IMAGE)
    end
  end

  def build_running_service
    build_service.tap do |service|
      service.instance_variable_set(:@container_name, "hitch-checkpoint-redis-test")
      service.instance_variable_set(:@container_id, "container-id")
      service.instance_variable_set(:@url, "redis://127.0.0.1:6379/15")
    end
  end
end
