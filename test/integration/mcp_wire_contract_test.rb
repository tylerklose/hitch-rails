# frozen_string_literal: true

# M2.2 replaces this manifest-only module with fixture-driven endpoint tests.
# There is deliberately no skipped test: M1 contract preparation is not runtime
# evidence and must not make the M0 suite appear partly accepted.
module HitchMcpWireContractPending
  ACTIVATES_WHEN = "Hitch::MCP::Endpoint"
  TEST_NAMES = %w[
    test_modern_envelope_and_header_vectors
    test_reserved_server_context_forms
    test_exact_http_and_protocol_mapping
    test_single_parse_and_dispatch
    test_forwarded_host_proto_and_port_cannot_change_canonical_origin
  ].freeze
end
