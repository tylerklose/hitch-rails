# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Reports a synthetic failure with caller-fixed context through the host
      # error reporter. The original exception never crosses this boundary, and
      # every reporting failure is swallowed.
      class SanitizedReport
        class ReportedFailure < StandardError; end

        class << self
          def emit(source:, context:, message:)
            return unless Rails.respond_to?(:error)

            failure = ReportedFailure.new(message)
            failure.set_backtrace(caller(1, 8))
            failure.freeze
            Rails.error.report(
              failure,
              handled: true,
              severity: :error,
              context: context,
              source: source
            )
            nil
          rescue StandardError, SystemStackError
            nil
          end
        end

        private_constant :ReportedFailure
      end
    end
  end
end
