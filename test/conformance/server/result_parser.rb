# frozen_string_literal: true

require "yaml"

module Hitch
  module Conformance
    module Server
      class ResultParser
        class Failure < StandardError; end

        SCENARIOS = %w[
          server-stateless
          http-header-validation
          dns-rebinding-protection
          json-schema-2020-12
          tools-list
          tools-call-simple-text
          tools-call-error
        ].freeze
        EXPECTED_FAILURES = %w[
          server-stateless:sep-2575-server-rejects-undeclared-capability
          server-stateless:sep-2575-missing-capability-http-400
        ].freeze
        EXPECTED_SKIPS = %w[
          server-stateless:sep-2575-server-sends-subscription-ack
          server-stateless:sep-2575-server-tags-subscription-id
          server-stateless:sep-2575-server-honors-notification-filter
          server-stateless:sep-2575-server-sends-prompts-list-changed-on-subscription
          server-stateless:sep-2575-server-sends-tools-list-changed-on-subscription
        ].freeze
        EXCLUSIONS = {
          "caching" => "unconditionally probes prompts and resources, which Hitch 0.2 does not implement"
        }.freeze
        STATUSES = %w[SUCCESS FAILURE WARNING SKIPPED INFO].freeze

        def self.call(results:, expected_failures_path:)
          new(results, expected_failures_path).call
        end

        def initialize(results, expected_failures_path)
          @results = results
          @expected_failures_path = expected_failures_path
        end

        def call
          errors = []
          validate_scenarios!(errors)
          rows = normalized_rows(errors)
          validate_baseline!(rows, errors)
          validate_skips!(rows, errors)
          raise Failure, errors.uniq.join("; ") if errors.any?

          {
            scenarios: SCENARIOS,
            checks: rows.map { |row| row.fetch(:public) },
            counts: STATUSES.to_h { |status| [ status.downcase, rows.count { |row| row[:status] == status } ] },
            expected_failures: EXPECTED_FAILURES,
            expected_failure_probe: "runner-only test_missing_capability was listed and executed without -32021",
            capability_gated_skips: EXPECTED_SKIPS,
            exclusions: EXCLUSIONS
          }
        end

        private

        attr_reader :results, :expected_failures_path

        def validate_scenarios!(errors)
          actual = results.keys.map(&:to_s).sort
          errors << "scenario selection drifted" unless actual == SCENARIOS.sort
          SCENARIOS.each do |scenario|
            errors << "#{scenario} emitted no checks" unless results[scenario].is_a?(Array) && results[scenario].any?
          end
        end

        def normalized_rows(errors)
          SCENARIOS.flat_map do |scenario|
            Array(results[scenario]).filter_map do |check|
              unless check.is_a?(Hash) && check["id"].is_a?(String) && check["status"].is_a?(String)
                errors << "#{scenario} emitted a malformed check"
                next
              end
              status = check.fetch("status")
              errors << "#{scenario}:#{check['id']} emitted unknown status #{status}" unless STATUSES.include?(status)
              {
                scenario: scenario,
                id: check.fetch("id"),
                status: status,
                error_message: check["errorMessage"],
                public: check.slice("id", "name", "description", "status", "specReferences").merge(
                  "scenario" => scenario
                )
              }
            end
          end
        end

        def validate_baseline!(rows, errors)
          baseline = YAML.safe_load_file(expected_failures_path, permitted_classes: [], aliases: false)
          unless baseline == { "schema_version" => 1, "server" => EXPECTED_FAILURES }
            errors << "expected-failure baseline differs from the exact two reviewed checks"
            return
          end

          failing = rows.select { |row| %w[FAILURE WARNING].include?(row[:status]) }
          grouped = rows.group_by { |row| "#{row[:scenario]}:#{row[:id]}" }
          unexpected = failing.map { |row| "#{row[:scenario]}:#{row[:id]}" }.uniq - EXPECTED_FAILURES
          errors << "unexpected failures: #{unexpected.join(', ')}" if unexpected.any?

          EXPECTED_FAILURES.each do |entry|
            statuses = Array(grouped[entry]).map { |row| row[:status] }
            errors << "expected failure was not emitted: #{entry}" if statuses.empty?
            errors << "expected failure became a demonstrated pass: #{entry}" if statuses.include?("SUCCESS")
            errors << "expected failure did not fail: #{entry}" unless statuses.any? { |status| %w[FAILURE WARNING].include?(status) }
            if entry == EXPECTED_FAILURES.first &&
                Array(grouped[entry]).any? { |row| row[:error_message].to_s.start_with?("Not testable:") }
              errors << "expected failure was not testable: #{entry}"
            end
          end
        rescue Errno::ENOENT, Psych::Exception => error
          errors << "invalid expected-failure baseline: #{error.message}"
        end

        def validate_skips!(rows, errors)
          skipped = rows.select { |row| row[:status] == "SKIPPED" }
            .map { |row| "#{row[:scenario]}:#{row[:id]}" }.uniq
          errors << "capability-gated skip set drifted" unless skipped.sort == EXPECTED_SKIPS.sort
        end
      end
    end
  end
end
