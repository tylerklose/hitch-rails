# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = ENV["HITCH_CONFORMANCE"] == "1"

  # Conformance and migration gates use disposable databases. Never let those
  # adapter-specific runs rewrite the canonical checked-in dummy schema.
  config.active_record.dump_schema_after_migration = false if ENV["HITCH_CONFORMANCE"] == "1"

  if (conformance_log = ENV["HITCH_CONFORMANCE_RAILS_LOG"]).present?
    # The harness pre-creates this file at 0600. Give Rails and Active Record
    # the same logger so no request/SQL output falls back to the workspace's
    # ignored test/dummy/log/test.log.
    log_io = File.open(conformance_log, File::WRONLY | File::APPEND | File::CREAT, 0o600)
    log_io.sync = true
    config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(log_io))
  end

  if (canary_file = ENV["HITCH_CONFORMANCE_CANARY_FILE"]).present?
    require Rails.root.join("../conformance/authorization/credential_canary_middleware").to_s
    config.middleware.use Hitch::Conformance::CredentialCanaryMiddleware, path: canary_file
  end

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
