# frozen_string_literal: true

require "json"

gate_path = ENV.fetch("HITCH_RATE_LIMIT_GATE_FILE")
ready_path = ENV.fetch("HITCH_RATE_LIMIT_READY_FILE")
result_path = ENV.fetch("HITCH_RATE_LIMIT_RESULT_FILE")
token_path = ENV.fetch("HITCH_RATE_LIMIT_TOKEN_FILE")
calls = Integer(ENV.fetch("HITCH_RATE_LIMIT_CALLS"), 10)
abort "HITCH_RATE_LIMIT_CALLS must be positive" unless calls.positive?

token_stat = File.stat(token_path)
abort "rate-limit token file must be mode 0600" unless (token_stat.mode & 0o077).zero?
token = File.binread(token_path)
abort "rate-limit token file is empty" if token.empty?

File.write(ready_path, Process.pid.to_s)
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
until File.exist?(gate_path)
  abort "timed out waiting for the rate-limit process gate" if
    Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep 0.01
end

body = JSON.generate(
  jsonrpc: "2.0",
  id: "cross-process",
  method: "tools/list",
  params: {
    "_meta" => {
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => {}
    }
  }
)
statuses = []
retry_after = []
started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

calls.times do
  environment = Rack::MockRequest.env_for(
    "https://dummy.test/mcp",
    method: "POST",
    input: body,
    "HTTP_HOST" => "dummy.test",
    "HTTP_AUTHORIZATION" => "Bearer #{token}",
    "HTTP_ACCEPT" => "application/json, text/event-stream",
    "CONTENT_TYPE" => "application/json",
    "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28",
    "HTTP_MCP_METHOD" => "tools/list",
    "HTTP_X_HITCH_WIRE_ADMISSION" => "runtime"
  )
  status, headers, response = Rails.application.call(environment)
  response.each { |_part| nil }
  response.close if response.respond_to?(:close)
  statuses << status
  retry_after << headers["retry-after"] if status == 429
end

File.write(result_path, JSON.pretty_generate(
  pid: Process.pid,
  calls:,
  statuses:,
  retry_after:,
  elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000).round
))
