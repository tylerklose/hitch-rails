# frozen_string_literal: true

# M4.5 replaces this manifest-only module with the exhaustive runtime oracle.
module HitchMcpToolAuthorizationLatticePending
  ACTIVATES_WHEN = "Hitch::MCP::Tool"
  TEST_NAMES = %w[
    test_exhaustive_terminal_paths
    test_expired_and_revoked_concrete_variants
    test_event_and_host_work_counts
  ].freeze
end
