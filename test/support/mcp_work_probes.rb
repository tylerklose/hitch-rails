# frozen_string_literal: true

# Counts the endpoint's downstream work by spying on the real collaborators —
# the body parse, the registry snapshot read, and the SDK dispatch — so the
# zero-work and single-dispatch invariants stay assertable without the
# endpoint carrying test seams. Each probe delegates straight through; the
# production path is what runs.
module McpWorkProbes
  def self.install!
    return if @installed

    @installed = true
    Hitch::MCP::Internal::VerifiedRequest.singleton_class.prepend(BodyParse)
    Hitch::MCP::Configuration.prepend(RegistrySnapshot)
    Hitch::MCP::Internal::SDKAdapter.singleton_class.prepend(SDKDispatch)
  end

  module BodyParse
    def call(...)
      McpController.increment_wire_metric!(:body_parses)
      super
    end
  end

  # Counts only successful snapshot reads, exactly as the endpoint proceeds.
  module RegistrySnapshot
    def registry_snapshot!
      super.tap { McpController.increment_wire_metric!(:registry) }
    end
  end

  module SDKDispatch
    def call(...)
      McpController.increment_wire_metric!(:sdk)
      super
    end
  end
end
