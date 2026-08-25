# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# The rate-limit-store checks run only in production, so nothing in this suite
# executed them until this file existed — and the dummy app configures
# mcp.rate_limit_store explicitly, so the fall back to the application's own
# cache store, which is the default every adopter gets, was executed nowhere at
# all.
#
# That gap shipped a boot-killing ArgumentError once. Unit tests could not have
# caught it: the defect was *when* the default store gets resolved relative to
# Rails' own initializers, and any in-process test has already finished booting.
# So this boots a real application in a real subprocess.
class Hitch::ProductionBootTest < ActiveSupport::TestCase
  test "boots when the rate-limit store falls back to a shared application store" do
    stdout, stderr, status = boot("shared")

    assert_predicate status, :success?, "production boot failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "BOOTED"
  end

  test "refuses the boot when the fallback store cannot count across processes" do
    _stdout, stderr, status = boot("unshared")

    refute_predicate status, :success?, "an unshared store must fail the boot, not the first request"
    assert_includes stderr, "mcp.rate_limit_store"
    assert_includes stderr, "cannot count one caller's"
  end

  test "production doctor drives the configured DCR store in a real task process" do
    assert_broken_feature_store("dcr", "config.dynamic_client_registration_rate_store")
  end

  test "production doctor drives the configured device store in a real task process" do
    assert_broken_feature_store("device", "config.device_authorization_rate_store")
  end

  private

  def boot(probe)
    Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE" => "hitch-production-boot-probe",
        "HITCH_BOOT_PROBE" => probe
      },
      File.join(repository_root, "bin/rails"), "runner", "puts 'BOOTED'",
      chdir: repository_root
    )
  end

  def assert_broken_feature_store(probe, setting)
    secret = "doctor-store-secret-#{probe}"
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => production_database_url,
        "SECRET_KEY_BASE" => "hitch-production-doctor-probe",
        "HITCH_DOCTOR_FORMAT" => "json",
        "HITCH_DOCTOR_STORE_PROBE" => probe,
        "HITCH_DOCTOR_STORE_SECRET" => secret,
        # Load the dummy host without putting its path in ARGV. The engine
        # must see the real task name so Doctor can report a bad boot store.
        "RAKEOPT" => "-ftest/dummy/Rakefile"
      },
      "bundle", "exec", "rake", "hitch:doctor",
      chdir: repository_root
    )
    json_output = stdout.lines.drop_while { |line| line != "{\n" }.join
    document = JSON.parse(json_output)
    check = document.fetch("checks").find { |candidate| candidate.fetch("id") == "configuration" }

    refute_predicate status, :success?, "broken production store passed doctor:\n#{stdout}\n#{stderr}"
    assert_equal [ "fail", "#{probe == 'dcr' ? 'dynamic_client_registration' : 'device_authorization'}_rate_store_invalid" ],
      check.values_at("status", "code")
    assert_equal setting, check.dig("details", "setting")
    assert_equal "Hitch::DoctorProbeStore", check.dig("details", "store_class")
    refute_includes json_output, secret
    refute_includes stderr, secret
  end

  def production_database_url
    ENV["DATABASE_URL"].presence || begin
      database = ActiveRecord::Base.connection_db_config.database
      if ActiveRecord::Base.connection_db_config.adapter == "sqlite3"
        "sqlite3:#{database}"
      else
        "postgresql:///#{database}"
      end
    end
  end

  def repository_root
    Rails.root.join("../..").expand_path.to_s
  end
end
