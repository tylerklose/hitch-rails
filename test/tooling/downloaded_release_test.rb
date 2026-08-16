# frozen_string_literal: true

require "test_helper"
require_relative "../../tooling/downloaded_release"

class DownloadedReleaseTest < ActiveSupport::TestCase
  test "accepts a fresh live verification time for identical immutable evidence" do
    accepted = evidence("2026-08-03T12:00:00Z")
    live = evidence("2026-08-03T13:00:00Z")

    assert HitchDownloadedRelease.reconcile!(accepted:, live:)
  end

  test "reports every immutable live mismatch" do
    accepted = evidence("2026-08-03T12:00:00Z")
    live = evidence("2026-08-03T13:00:00Z")
    live["rubygems"]["sha256"] = "9" * 64
    live["repository"]["target_commit"] = "8" * 40

    error = assert_raises(HitchDownloadedRelease::VerificationError) do
      HitchDownloadedRelease.reconcile!(accepted:, live:)
    end

    assert_includes error.message, "rubygems.sha256"
    assert_includes error.message, "repository.target_commit"
  end

  test "rejects a live report without a real verification time" do
    error = assert_raises(HitchDownloadedRelease::VerificationError) do
      HitchDownloadedRelease.reconcile!(
        accepted: evidence("2026-08-03T12:00:00Z"),
        live: evidence("handwritten")
      )
    end

    assert_includes error.message, "ISO-8601"
  end

  private

  def evidence(verified_at)
    {
      "schema" => "hitch.m8-downloaded-gem.v1",
      "verified_at" => verified_at,
      "rubygems" => { "artifact" => "hitch-rails-0.2.0.gem", "sha256" => "a" * 64 },
      "repository" => { "tag" => "v0.2.0", "target_commit" => "b" * 40 }
    }
  end
end
