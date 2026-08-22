# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # A client must learn nothing from a host failure; the developer who
      # wrote it must learn everything. Those are two audiences and only the
      # first is a threat, so in development and test the real exception goes
      # to the local log. Callers' wire responses are unchanged, and
      # production stays silent.
      module LocalDiagnosis
        module_function

        def report(subject, error = nil)
          return unless Rails.env.local?

          lines = [ "[hitch] #{subject}" ]
          if error
            lines << "  #{error.class}: #{error.message}"
            lines.concat(Array(error.backtrace).first(5).map { |line| "    #{line}" })
          end
          Rails.logger&.error(lines.join("\n"))
          nil
        # Diagnosing a failure must not become one.
        rescue StandardError, SystemStackError
          nil
        end
      end
    end
  end
end
