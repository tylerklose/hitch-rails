# frozen_string_literal: true

require "test_helper"
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

  def repository_root
    Rails.root.join("../..").expand_path.to_s
  end
end
