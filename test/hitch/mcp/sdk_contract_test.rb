# frozen_string_literal: true

# Named M1 contract tests. M2.1 replaces this manifest-only module with
# executable tests after Hitch::MCP::SDKAdapter exists. Keeping the names in a
# real test path makes ownership searchable without adding misleading skips to
# the auth-only M0 suite.
module HitchMcpSdkContractPending
  ACTIVATES_WHEN = "Hitch::MCP::SDKAdapter"
  TEST_NAMES = %w[
    test_handle_requires_structural_symbol_keys
    test_final_meta_accepts_absent_client_info
    test_hostile_global_callbacks_receive_no_hitch_request_data
    test_tool_name_host_subset_documents_sdk_1_1_divergence
  ].freeze
end
