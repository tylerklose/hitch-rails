# frozen_string_literal: true

module Hitch
  module MCP
    # Raised by host argument policy to deny one otherwise admissible tool call.
    # Its message is always private and never crosses the MCP boundary.
    class Forbidden < StandardError
    end
  end
end
