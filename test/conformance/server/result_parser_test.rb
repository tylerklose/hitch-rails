# frozen_string_literal: true

require "test_helper"
require Rails.root.join("../conformance/server/result_parser").to_s

class ServerConformanceResultParserTest < ActiveSupport::TestCase
  setup do
    @baseline = Rails.root.join("../conformance/expected-failures.yml")
  end

  test "accepts only the exact failures and visible capability skips" do
    report = parse(results)

    assert_equal 2, report.dig(:counts, "failure")
    assert_equal 5, report.dig(:counts, "skipped")
    assert_equal Hitch::Conformance::Server::ResultParser::EXPECTED_FAILURES,
      report.fetch(:expected_failures)
  end

  test "rejects a new failure outside the baseline" do
    value = results
    value.fetch("tools-list") << check("new-failure", "FAILURE")

    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "unexpected failures"
  end

  test "rejects a baseline check that becomes a demonstrated pass" do
    value = results
    target = value.fetch("server-stateless").find do |check|
      check.fetch("id") == "sep-2575-server-rejects-undeclared-capability"
    end
    target["status"] = "SUCCESS"

    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "became a demonstrated pass"
  end

  test "rejects an absent expected failure" do
    value = results
    value.fetch("server-stateless").reject! do |check|
      check.fetch("id") == "sep-2575-missing-capability-http-400"
    end

    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "was not emitted"
  end

  test "rejects a baseline failure caused only by a missing diagnostic fixture" do
    value = results
    target = value.fetch("server-stateless").find do |check|
      check.fetch("id") == "sep-2575-server-rejects-undeclared-capability"
    end
    target["errorMessage"] = "Not testable: diagnostic tool missing"

    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "was not testable"
  end

  test "rejects capability skips counted as successes or widened with a new skip" do
    value = results
    value.fetch("server-stateless").find { |row| row.fetch("status") == "SKIPPED" }["status"] = "SUCCESS"
    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "skip set drifted"

    value = results
    value.fetch("tools-list") << check("unreviewed-skip", "SKIPPED")
    error = assert_raises(Hitch::Conformance::Server::ResultParser::Failure) { parse(value) }
    assert_includes error.message, "skip set drifted"
  end

  private

  def parse(value)
    Hitch::Conformance::Server::ResultParser.call(
      results: value,
      expected_failures_path: @baseline
    )
  end

  def results
    scenarios = Hitch::Conformance::Server::ResultParser::SCENARIOS.to_h do |scenario|
      [ scenario, [ check("#{scenario}-success", "SUCCESS") ] ]
    end
    Hitch::Conformance::Server::ResultParser::EXPECTED_FAILURES.each do |entry|
      scenario, id = entry.split(":", 2)
      scenarios.fetch(scenario) << check(id, "FAILURE")
    end
    Hitch::Conformance::Server::ResultParser::EXPECTED_SKIPS.each do |entry|
      scenario, id = entry.split(":", 2)
      scenarios.fetch(scenario) << check(id, "SKIPPED")
    end
    Marshal.load(Marshal.dump(scenarios))
  end

  def check(id, status)
    {
      "id" => id,
      "name" => id,
      "description" => id,
      "status" => status,
      "specReferences" => []
    }
  end
end
