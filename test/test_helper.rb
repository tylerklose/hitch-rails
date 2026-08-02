# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"
require_relative "support/access_token_exchange"
require_relative "support/rack_input"

# db:test:prepare can load schema.rb without replaying the migration's data
# insert. Production installs run db:migrate; tests recreate the one durable
# authority row explicitly so missing-state behavior remains fail-closed.
if ActiveRecord::Base.connection.data_source_exists?("hitch_schema_states")
  Hitch::SchemaState.find_or_create_by!(key: Hitch::SchemaState::REDIRECT_URIS_KEY) do |state|
    state.version = 2
  end
end

# Minitest 6 no longer ships minitest/mock, and this gem deliberately
# carries no test-double dependency. This is the whole of what the suite
# needs: swap a singleton method for the duration of a block and put the
# original back, visibility included, even if the block raises.
module StubClassMethod
  def stub_class_method(klass, name, replacement)
    singleton = klass.singleton_class
    original = singleton.instance_method(name)
    visibility = if singleton.private_method_defined?(name) then :private
    elsif singleton.protected_method_defined?(name) then :protected
    else :public
    end

    singleton.send(:define_method, name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    singleton.send(visibility, name)
    yield
  ensure
    singleton.send(:define_method, name, original)
    singleton.send(visibility, name)
  end
end

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

ActiveSupport::TestCase.include(StubClassMethod)
ActiveSupport::TestCase.include(AccessTokenExchange)
ActiveSupport::TestCase.include(RackInputTestSupport)

# The dummy app's configured MCP resource is HTTPS. Make integration requests
# arrive through the same effective origin production requires; individual
# tests that exercise loopback HTTP can opt out with `https!(false)`.
ActionDispatch::IntegrationTest.setup { https! }
