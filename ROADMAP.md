# Roadmap

Hitch's direction is to become the opinionated Rails framework for providing
MCP tools — from OAuth through an explicit registry and safe invocation
conventions — while the host application keeps owning its business logic and
authorization policy.

## Next

- Generator and developer-experience polish: generated tools that work out of
  the box, fewer install moving parts, better failure messages.
- Track the MCP specification and Ruby SDK as they evolve, staying on the
  current authorization profile.

## Explicitly later

- SSE, cancellation, progress, subscriptions, and input-required results
- Prompts, resources, tasks, and Apps
- Multiple named surfaces/resources/registries
- API-only consent/auth patterns and MySQL
- `client_secret_post`, JWT/mTLS/DPoP, device flow
- Named authorization adapters or bundled Pundit integration
- Per-tool quotas, distributed concurrency leases, a Hitch-owned admission
  store, and framework-owned durable audit persistence
- Automatic tool discovery, including the seed below

## Seed: controller/action-shaped tools

Rails may have a more natural host-side convention than one class per MCP tool
plus a separately edited registry: a controller-like class that groups related
tools, its public actions describing individual MCP calls. Before that can
change the framework contract, design work has to answer what makes an action
an exposed tool rather than an accidentally public method, where schemas and
scopes are declared, and how deny-by-default availability and reloading stay
deterministic. For 0.2, configuration names one explicit registry and tools
are never auto-discovered; this seed exists so real host examples can flesh
out or reject the convention.

## References

- [MCP 2026-07-28 specification](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [Ruby MCP SDK](https://github.com/modelcontextprotocol/ruby-sdk)
- [Official conformance runner](https://github.com/modelcontextprotocol/conformance)
