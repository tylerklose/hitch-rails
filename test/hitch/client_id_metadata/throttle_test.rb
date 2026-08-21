# frozen_string_literal: true

require "test_helper"

# First direct coverage of the outbound-fetch throttle — previously testable
# only through stubbed HTTP resolutions.
class Hitch::ClientIdMetadata::ThrottleTest < ActiveSupport::TestCase
  setup do
    @throttle = Hitch::ClientIdMetadata::Throttle.new
  end

  test "a nil capacity limit disables the cap" do
    assert_equal :ran, @throttle.with_capacity(nil) { :ran }
  end

  test "a zero capacity limit blocks every fetch" do
    ran = false
    result = @throttle.with_capacity(0) { ran = true }

    assert_equal Hitch::ClientIdMetadata::Throttle::CAPACITY_EXCEEDED, result
    refute ran
  end

  test "slots refuse rather than queue at the limit and free on completion" do
    inside = @throttle.with_capacity(1) do
      assert_equal 1, @throttle.in_flight
      @throttle.with_capacity(1) { flunk "second slot must be refused" }
    end

    assert_equal Hitch::ClientIdMetadata::Throttle::CAPACITY_EXCEEDED, inside
    assert_equal 0, @throttle.in_flight
    assert_equal :ran, @throttle.with_capacity(1) { :ran }
  end

  test "a slot is released when the block raises" do
    assert_raises(RuntimeError) { @throttle.with_capacity(1) { raise "boom" } }
    assert_equal 0, @throttle.in_flight
    assert_equal :ran, @throttle.with_capacity(1) { :ran }
  end

  test "slots are refused across threads while held" do
    held = Queue.new
    release = Queue.new
    holder = Thread.new do
      @throttle.with_capacity(1) do
        held << true
        release.pop
        :held
      end
    end

    held.pop
    assert_equal Hitch::ClientIdMetadata::Throttle::CAPACITY_EXCEEDED,
      @throttle.with_capacity(1) { flunk "slot is held by the other thread" }

    release << true
    assert_equal :held, holder.value
    assert_equal 0, @throttle.in_flight
  end

  test "the minute budget is exact per actor and independent between actors" do
    now = Time.at(1_700_000_040)

    assert @throttle.charge("User:1", limit: 2, now: now)
    assert @throttle.charge("User:1", limit: 2, now: now)
    refute @throttle.charge("User:1", limit: 2, now: now)
    assert_equal 2, @throttle.charged_to("User:1", now: now)

    assert @throttle.charge("User:2", limit: 2, now: now)
    assert_equal 1, @throttle.charged_to("User:2", now: now)
  end

  test "the budget resets when the fixed window rolls over" do
    first_window = Time.at(1_700_000_040)
    next_window = first_window + 60

    assert @throttle.charge("User:1", limit: 1, now: first_window)
    refute @throttle.charge("User:1", limit: 1, now: first_window)

    assert @throttle.charge("User:1", limit: 1, now: next_window)
    assert_equal 1, @throttle.charged_to("User:1", now: next_window)
    assert_equal 0, @throttle.charged_to("User:1", now: next_window + 60)
  end

  test "a lowered limit applies to already-spent windows" do
    now = Time.at(1_700_000_040)
    3.times { assert @throttle.charge("User:1", limit: 3, now: now) }

    refute @throttle.charge("User:1", limit: 2, now: now)
  end
end
