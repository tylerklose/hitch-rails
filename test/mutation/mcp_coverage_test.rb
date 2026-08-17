# frozen_string_literal: true

# Mutant loads this file after the ordinary test suites and adds `cover` to
# Minitest::Test. Normal Rails test runs deliberately leave these declarations
# inert; the mutation gate owns only the exact framework methods listed here.
if Minitest::Test.respond_to?(:cover)
  class Hitch::AccessTokenTest
    cover "Hitch::AccessToken#valid_for_resource?"
  end

  class MCPRateLimitCacheStoreTest
    cover "Hitch::MCP::Endpoint#hitch_mcp_admit_authenticated_request"
  end

  class Hitch::MCP::RegistryTest
    cover "Hitch::MCP::Registry.validate_snapshot!"
    cover "Hitch::MCP::Internal::SchemaContract#call"
    cover "Hitch::MCP::Registry.scopes_granted?"
  end

  class Hitch::MCP::SDKContractTest
    cover "Hitch::MCP::Internal::SDKAdapter#sdk_configuration"
    cover "Hitch::MCP::Internal::SDKAdapter#reserved_server_context?"
  end

  class Hitch::MCP::ToolTest
    cover "Hitch::MCP::Tool.available_to?"
    cover "Hitch::MCP::Tool.authorize!"
    cover "Hitch::MCP::Tool.perform"
  end

  class Hitch::MCP::ResultTest
    cover "Hitch::MCP::Internal::ResultNormalizer#call"
    cover "Hitch::MCP::Internal::ErrorNormalizer.generic_response"
    cover "Hitch::MCP::Internal::ErrorNormalizer.expected_denial?"
  end

  class Hitch::MCP::ContextTest
    cover "Hitch::MCP::Context#deep_copy_json"
  end

  class Hitch::MCP::ObservationTest
    cover "Hitch::MCP::Internal::Observation.publish"
  end
end
