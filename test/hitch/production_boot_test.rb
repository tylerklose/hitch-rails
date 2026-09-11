# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

# Production-only rate-limit-store behaviour. The dummy app configures
# mcp.rate_limit_store explicitly, so the fall back to the application's own
# cache store — the default every adopter gets — is exercised nowhere else.
# That gap shipped a boot-killing ArgumentError once. This boots a real
# application in a real subprocess: production still comes up with an
# unshared fallback, and hitch raises when it counts.
class Hitch::ProductionBootTest < ActiveSupport::TestCase
  test "boots when the rate-limit store falls back to a shared application store" do
    stdout, stderr, status = boot("shared")

    assert_predicate status, :success?, "production boot failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "BOOTED"
  end

  test "boots when the fallback store cannot count across processes" do
    stdout, stderr, status = boot("unshared")

    assert_predicate status, :success?, "production boot failed:\n#{stdout}\n#{stderr}"
    assert_includes stdout, "BOOTED"
  end

  test "an unshared production store raises when hitch counts, after boot" do
    stdout, stderr, status = boot("unshared", script: <<~RUBY)
      puts "BOOTED"
      Hitch::RateLimitStore.check!(
        Hitch.configuration.mcp.rate_limit_store,
        "hitch:boot-probe",
        { to: 1, within: 60 },
        setting: "mcp.rate_limit_store"
      )
    RUBY

    assert_includes stdout, "BOOTED"
    refute_predicate status, :success?, "counting on an unshared store must raise:\n#{stdout}\n#{stderr}"
    assert_includes stderr, "mcp.rate_limit_store"
    assert_includes stderr, "ActiveSupport::Cache::MemoryStore"
    assert_includes stderr, "cannot count one caller's"
  end

  test "production doctor drives the configured DCR store in a real task process" do
    assert_broken_feature_store("dcr", "config.dynamic_client_registration_rate_store")
  end

  test "production doctor drives the configured device store in a real task process" do
    assert_broken_feature_store("device", "config.device_authorization_rate_store")
  end

  test "bin rails doctor resolves a framework-touching registry after initialization" do
    stdout, stderr, _status = Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => production_database_url,
        "SECRET_KEY_BASE" => "hitch-production-doctor-early-load-probe",
        "HITCH_DOCTOR_FORMAT" => "json",
        "HITCH_DOCTOR_EARLY_LOAD_PROBE" => "1"
      },
      File.join(dummy_root, "bin/rails"), "hitch:doctor",
      chdir: dummy_root
    )
    json_output = stdout.lines.drop_while { |line| line != "{\n" }.join
    document = JSON.parse(json_output)
    registry = document.fetch("checks").find { |check| check.fetch("id") == "registry" }

    assert_equal [ "pass", "valid" ], registry.values_at("status", "code")
    refute_includes "#{stdout}\n#{stderr}", "loaded before application initialization"
  end

  private

  def boot(probe, script: "puts 'BOOTED'")
    Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE" => "hitch-production-boot-probe",
        "HITCH_BOOT_PROBE" => probe
      },
      File.join(repository_root, "bin/rails"), "runner", script,
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

  def dummy_root
    Rails.root.to_s
  end
end
