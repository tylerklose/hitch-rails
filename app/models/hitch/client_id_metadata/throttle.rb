# frozen_string_literal: true

module Hitch
  class ClientIdMetadata
    # Process-local guards on outbound metadata fetches: a concurrency cap
    # on fetch slots and a fixed-window per-actor minute budget.
    #
    # Deliberately in-process rather than in Rails.cache. A cache-backed
    # counter needs read, compare and write as one operation; done as three,
    # N callers admitted by the concurrency cap each read the same value and
    # each write value+1, so the counter advances by one while N fetches
    # proceed — measured at 4x the configured limit with a cap of 4. Keeping
    # it in-process makes it atomic by construction, and drops the two
    # failure modes the cache-backed version had to warn about: a cache
    # outage and a store whose writes silently fail both left the limit not
    # applying at all. The cost is that each bound is per process, so a
    # fleet ceiling is the configured value times the worker count — stated
    # rather than implied.
    class Throttle
      # Refused because every slot was already spent — no fetch attempted.
      # Says NOTHING about the URL or the host, so callers must never cache
      # it: writing a host failure would turn cap exhaustion into a way to
      # poison a legitimate host's entry for everyone.
      CAPACITY_EXCEEDED = :capacity_exceeded

      def initialize
        @capacity_mutex = Mutex.new
        @in_flight = 0
        @rate_mutex = Mutex.new
        @rate_counts = {}
        @rate_window = nil
      end

      # Runs the block while holding one of `limit` slots, or returns
      # CAPACITY_EXCEEDED without running it. nil disables; integers are
      # honored literally — including 0, which blocks every fetch. Treating
      # 0 as "disabled" would make the most restrictive-looking setting the
      # least restrictive one. Fails closed, and refuses rather than
      # queues: queueing is what consumes the request thread this cap
      # exists to protect.
      def with_capacity(limit)
        return yield if limit.nil?

        # The increment and the ensure that undoes it must not be
        # separable by an asynchronous exception. Rack::Timeout, an outer
        # Timeout.timeout, or Puma's force_shutdown_after all deliver via
        # Thread#raise, and one landing between the two would leak the
        # slot permanently — after `limit` of those, CIMD is dead for the
        # life of the process, silently and with nothing to alert on.
        #
        # Not covered by a test, deliberately. Review measured the
        # unmasked window at up to 30% leakage in an isolated harness,
        # but in situ Ruby already defers async interrupts across much of
        # Mutex#synchronize, so the window is far narrower: a test driving
        # Thread#raise at it stayed green against a no-op stand-in for
        # this mask across repeated runs, while hanging the suite and
        # emitting thread-death noise. A test that cannot fail for the
        # reason it exists is worse than none, so the mask rests on that
        # measurement and on this comment.
        Thread.handle_interrupt(Object => :never) do
          acquired = @capacity_mutex.synchronize do
            next false if @in_flight >= limit

            @in_flight += 1
            true
          end

          next CAPACITY_EXCEEDED unless acquired

          begin
            Thread.handle_interrupt(Object => :immediate) { yield }
          ensure
            @capacity_mutex.synchronize { @in_flight -= 1 }
          end
        end
      end

      # Charges one fetch to `actor` in the current fixed 60-second window;
      # false once the actor's `limit` is spent. Coarse on purpose: a
      # sliding window buys precision that does not change what this
      # bounds — the order of magnitude of traffic one principal can aim
      # at a third party. A caller aligned to the boundary can spend two
      # windows back to back and briefly reach twice the nominal rate.
      def charge(actor, limit:, now: Time.now)
        window = now.to_i / 60

        # Check and increment under one lock. The hash holds one window at
        # a time and is dropped whole when the minute rolls over, so
        # charging is O(1) and memory is bounded by the distinct actors
        # seen within a single minute.
        @rate_mutex.synchronize do
          if @rate_window != window
            @rate_counts.clear
            @rate_window = window
          end

          key = actor.to_s
          spent = @rate_counts[key].to_i
          next false if spent >= limit

          @rate_counts[key] = spent + 1
          true
        end
      end

      def charged_to(actor, now: Time.now)
        @rate_mutex.synchronize do
          next 0 unless @rate_window == now.to_i / 60

          @rate_counts[actor.to_s].to_i
        end
      end

      def in_flight
        @capacity_mutex.synchronize { @in_flight.to_i }
      end
    end
  end
end
