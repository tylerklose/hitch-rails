# frozen_string_literal: true

require "test_helper"

class Hitch::EngineTest < ActiveSupport::TestCase
  test "host filter_parameters extended with OAuth secrets" do
    # Rails 8 consolidates filter_parameters into a single regex for
    # performance — assert behavior by actually filtering a sample hash
    # rather than introspecting the (post-consolidation) array shape.
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "code" => "raw_auth_code",
      "code_verifier" => "raw_verifier",
      "access_token" => "raw_access_token",
      "authorization_code" => "raw_auth_code",
      "token" => "raw_token",
      "client_name" => "Claude"  # control: not filtered
    )
    assert_equal "[FILTERED]", filtered["code"]
    assert_equal "[FILTERED]", filtered["code_verifier"]
    assert_equal "[FILTERED]", filtered["access_token"]
    assert_equal "[FILTERED]", filtered["authorization_code"]
    assert_equal "[FILTERED]", filtered["token"]
    assert_equal "Claude", filtered["client_name"]
  end

  # ActiveRecord's own db:load_config hook appends the engine's
  # db/migrate to DatabaseTasks.migrations_paths with `+=` and no dedupe
  # whenever ENGINE_ROOT is defined. If the engine's append_migrations
  # initializer contributes the same directory, it lands in that
  # collection twice and ActiveRecord::Schema.define raises "Duplicate
  # migration" while walking it — latent until a schema reload, which is
  # to say until someone adds a migration.
  test "no migration path is contributed twice" do
    paths = ActiveRecord::Tasks::DatabaseTasks.migrations_paths.map { |p| File.expand_path(p) }
    assert_equal paths.uniq, paths, "a duplicated migration path breaks every schema load"

    app_paths = Rails.application.config.paths["db/migrate"].expanded.map { |p| File.expand_path(p) }
    assert_equal app_paths.uniq, app_paths
  end
end
