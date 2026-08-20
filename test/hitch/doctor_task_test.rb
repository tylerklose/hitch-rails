# frozen_string_literal: true

require "test_helper"
require "hitch/doctor"
require "json"
require "rake"

class Hitch::DoctorTaskTest < ActiveSupport::TestCase
  Doctor = Hitch::Doctor

  setup do
    configure_host
    unless Rake::Task.task_defined?("hitch:doctor")
      Rake.application.rake_require("tasks/hitch", [ File.expand_path("../../lib", __dir__) ])
      Rake::Task.define_task(:environment)
    end
    @task = Rake::Task["hitch:doctor"]
  end

  teardown do
    @task&.reenable
    ENV.delete("HITCH_DOCTOR_FORMAT")
    configure_host
  end

  test "real task prints every human category without treating warnings as failure" do
    output, error_output, status = invoke

    assert_nil status
    assert_empty error_output
    assert_match(/\AHitch doctor v1: WARNING\n/, output)
    Doctor::CHECK_IDS.each { |id| assert_match(/\b#{Regexp.escape(id)}\b/, output) }
    assert_includes output, "unshared"
  end

  test "real task emits one stable machine document" do
    ENV["HITCH_DOCTOR_FORMAT"] = "json"

    output, error_output, status = invoke
    document = JSON.parse(output)

    assert_nil status
    assert_empty error_output
    assert_equal [ "schema", "status", "checks" ], document.keys
    assert_equal "hitch.doctor.v1", document.fetch("schema")
    assert_equal Doctor::CHECK_IDS, document.fetch("checks").map { |check| check.fetch("id") }
  end

  test "actionable report exits one after rendering" do
    report = Object.new
    report.define_singleton_method(:failure?) { true }
    replacement_call = -> { report }
    replacement_render = ->(_report, format:) { "format=#{format} failure\n" }

    stub_class_method(Doctor, :call, replacement_call) do
      stub_class_method(Doctor, :render, replacement_render) do
        output, error_output, status = invoke

        assert_equal 1, status
        assert_equal "format=human failure\n", output
        assert_empty error_output
      end
    end
  end

  test "unknown output format exits with an actionable error" do
    ENV["HITCH_DOCTOR_FORMAT"] = "yaml"
    replacement_call = -> { Object.new }

    stub_class_method(Doctor, :call, replacement_call) do
      output, error_output, status = invoke

      assert_equal 1, status
      assert_empty output
      assert_includes error_output, "HITCH_DOCTOR_FORMAT must be human or json"
    end
  end

  private

  def configure_host
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.allowed_hosts = [ "www.example.com", "dummy.test" ]
      configuration.allowed_origins = [ "https://claude.ai" ]
      configuration.dynamic_client_registration_enabled = true
      configuration.mcp.enabled = true
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = { name: "hitch-dummy", version: "0.2.0" }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to: 120, within: 60 }
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    end
  end

  def invoke
    output = StringIO.new
    error_output = StringIO.new
    original_output = $stdout
    original_error = $stderr
    $stdout = output
    $stderr = error_output
    status = nil
    begin
      @task.reenable
      @task.invoke
    rescue SystemExit => error
      status = error.status
    ensure
      $stdout = original_output
      $stderr = original_error
    end
    [ output.string, error_output.string, status ]
  end
end
