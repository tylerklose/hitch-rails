# frozen_string_literal: true

# These subjects were added after the original coverage set. They
# extend the live M8 mutation gate without rewriting that historical record.
if Minitest::Test.respond_to?(:cover)
  class Hitch::MCP::ObservationTest
    cover "Hitch::MCP::Internal::EndpointErrorReporter.reporting_context"
    cover "Hitch::MCP::Internal::Observation.correlation_id"
  end

  class Hitch::MCP::ResultTest
    cover "Hitch::MCP::Internal::ErrorNormalizer.reporting_context"
    cover "Hitch::MCP::Internal::JsonValues::Copier"
  end

  # The shared copier backs every JSON boundary; its dedicated policy-matrix
  # suite owns the engine's mutants, and the strongest boundary suites also
  # select against them through their production call sites.
  class Hitch::MCP::JsonValuesTest
    cover "Hitch::MCP::Internal::JsonValues::Copier"
  end

  class Hitch::MCP::ContextTest
    cover "Hitch::MCP::Internal::JsonValues::Copier"
  end

  class Hitch::MCP::ToolTest
    cover "Hitch::MCP::Internal::JsonValues::Copier"
  end

  class Hitch::MCP::RegistryTest
    cover "Hitch::MCP::Internal::JsonValues::Copier"
  end
end
