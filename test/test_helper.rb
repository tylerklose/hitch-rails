# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require_relative "support/access_token_exchange"
require_relative "support/rack_input"
require_relative "support/mcp_work_probes"

McpWorkProbes.install!

# Minitest 6 no longer ships minitest/mock, and this gem deliberately
# carries no test-double dependency. This is the whole of what the suite
# needs: swap a singleton method for the duration of a block and put the
# original back, visibility included, even if the block raises.
module StubClassMethod
  def stub_class_method(klass, name, replacement)
    singleton = klass.singleton_class
    original = singleton.instance_method(name)
    owned_visibility = if singleton.public_instance_methods(false).include?(name) then :public
    elsif singleton.protected_instance_methods(false).include?(name) then :protected
    elsif singleton.private_instance_methods(false).include?(name) then :private
    end
    visibility = if singleton.private_method_defined?(name) then :private
    elsif singleton.protected_method_defined?(name) then :protected
    else :public
    end

    singleton.send(:define_method, name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    singleton.send(visibility, name)
    yield
  ensure
    if owned_visibility
      singleton.send(:define_method, name, original)
      singleton.send(owned_visibility, name)
    else
      singleton.send(:remove_method, name)
    end
  end
end

# Hitch::ClientIdMetadata keeps one throttle per process, keyed by an actor
# string that is usually "User:1". A test that drives /oauth/authorize spends
# that budget, and the next test charging the same actor is silently refused —
# reported as an unrelated failure in whichever test the seed happened to run
# next. Scrub it for everyone rather than per class.
ActiveSupport::TestCase.teardown do
  Hitch::ClientIdMetadata.instance_variable_set(
    :@throttle, Hitch::ClientIdMetadata::Throttle.new
  )
  Hitch::ClientIdMetadata.instance_variable_set(:@warned, {})
end

ActiveSupport::TestCase.include(StubClassMethod)
ActiveSupport::TestCase.include(AccessTokenExchange)
ActiveSupport::TestCase.include(RackInputTestSupport)

# The dummy app's configured MCP resource is HTTPS. Make integration requests
# arrive through the same effective origin production requires; individual
# tests that exercise loopback HTTP can opt out with `https!(false)`.
ActionDispatch::IntegrationTest.setup { https! }
