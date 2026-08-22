# frozen_string_literal: true

require "test_helper"

# Rails 8.2 warns, with a full backtrace on every boot, when a load hook fires
# before application initialization has finished. Hitch tripped it twice by
# asking ActionController::Base for the default cache store while validating
# the rate-limit store at boot.
#
# The repair must not fix the warning by deferring the check into never: a
# store that cannot count across processes has to fail the boot, not the
# thousandth request. These drive both halves.
class Hitch::RateLimitStoreBootTest < ActiveSupport::TestCase
  SHARED = Class.new(ActiveSupport::Cache::Store) do
    def increment(name, amount = 1, **options) = 1
  end

  setup do
    @configured = SHARED.new
    @unshared = ActiveSupport::Cache::MemoryStore.new
  end

  test "a configured store is checked immediately and never touches the controller" do
    checked = nil

    without_action_controller_base do
      assert_raises(ArgumentError) do
        Hitch::RateLimitStore.assert_shared_at_boot!(@unshared, setting: "probe")
      end
      checked = Hitch::RateLimitStore.assert_shared_at_boot!(@configured, setting: "probe")
    end

    assert checked
  end

  test "the default store is not resolved while the controller stack is unloaded" do
    deferred = without_action_controller_base do
      # An unshared default would raise the moment it was resolved. It does not
      # raise here, which is the whole point: nothing asked for it yet.
      Hitch::RateLimitStore.assert_shared_at_boot!(nil, setting: "probe")
    end

    assert deferred
  end

  test "the deferred check still refuses an unshared default when the controller loads" do
    hook = nil

    without_action_controller_base do
      Hitch::RateLimitStore.assert_shared_at_boot!(nil, setting: "probe")
      hook = pending_hook
    end

    # Firing the hook is what Rails does when ActionController::Base finishes
    # loading, which in production happens during eager loading — still boot.
    stub_class_method(Hitch::RateLimitStore, :resolve, ->(_configured) { @unshared }) do
      error = assert_raises(ArgumentError) { ActionController::Base.instance_exec(&hook) }
      assert_includes error.message, "cannot count one caller's"
    end
  end

  test "mcp.validate_rate_limit_store! does not resolve the default at boot" do
    Hitch.configuration.mcp.rate_limit_store = nil

    resolved = false
    stub_class_method(Hitch::RateLimitStore, :resolve, ->(_c) { resolved = true; @unshared }) do
      without_action_controller_base do
        in_production { Hitch.configuration.mcp.validate_rate_limit_store! }
      end
    end

    refute resolved, "validate_rate_limit_store! asked for the default store during boot"
  end

  test "mcp.validate_rate_limit_store! still fails the boot for an unshared configured store" do
    Hitch.configuration.mcp.rate_limit_store = @unshared

    error = assert_raises(ArgumentError) do
      in_production { Hitch.configuration.mcp.validate_rate_limit_store! }
    end

    assert_includes error.message, "mcp.rate_limit_store"
  end

  test "the dynamic-registration store gets the same boot treatment" do
    Hitch.configuration.dynamic_client_registration_rate_store = @unshared

    error = assert_raises(ArgumentError) do
      Hitch.configuration.validate_dynamic_client_registration_rate_store!
    end

    assert_includes error.message, Hitch::DynamicRegistrationRateLimit::SETTING
  end

  private

  # ActiveSupport records which bases have already run a hook, and on_load
  # executes immediately against each. Emptying that list is what "the
  # controller stack has not loaded yet" looks like from on_load's side, which
  # is the state a real boot is in when Hitch's initializers run.
  def without_action_controller_base
    loaded = ActiveSupport.instance_variable_get(:@loaded)
    hooks = ActiveSupport.instance_variable_get(:@load_hooks)
    saved_bases = loaded[:action_controller_base].dup
    depth = hooks[:action_controller_base].length
    loaded[:action_controller_base] = []
    @hook_depth = depth

    yield
  ensure
    loaded[:action_controller_base] = saved_bases
    # Drop anything registered inside the block so it cannot fire later against
    # a real load and leak into another test.
    hooks[:action_controller_base] = hooks[:action_controller_base].first(depth)
  end

  def pending_hook
    ActiveSupport.instance_variable_get(:@load_hooks)[:action_controller_base]
      .drop(@hook_depth).last&.first
  end

  def in_production(&block)
    stub_class_method(Rails, :env, -> { ActiveSupport::StringInquirer.new("production") }, &block)
  end
end
