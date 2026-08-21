# frozen_string_literal: true

require "test_helper"
require "rake"

# The model-level diagnose tests all passed while the documented command
# exited without touching the network, because nothing exercised the task
# itself. This is that layer.
class Hitch::CimdCheckTaskTest < ActiveSupport::TestCase
  CIMD = Hitch::ClientIdMetadata
  DOC_URL = "https://client.example/metadata.json"

  setup do
    Hitch.reset_configuration!
    unless Rake::Task.task_defined?("hitch:cimd:check")
      Rake.application.rake_require("tasks/hitch", [ File.expand_path("../../lib", __dir__) ])
      Rake::Task.define_task(:environment)
    end
    @task = Rake::Task["hitch:cimd:check"]
  end

  teardown do
    @task&.reenable
    Hitch.reset_configuration!
  end

  def invoke(client_id)
    out = StringIO.new
    original, $stdout = $stdout, out
    begin
      @task.reenable
      @task.invoke(client_id)
      [ out.string, nil ]
    rescue SystemExit => e
      [ out.string, e.status ]
    ensure
      $stdout = original
    end
  end

  test "a reachable document reports ok and exits zero" do
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])
    stub_class_method(Hitch::ClientIdMetadata::Fetcher, :call, ->(_id, *) { [ document, 3600 ] }) do
      output, status = invoke(DOC_URL)
      assert_nil status, "a working probe must not exit non-zero"
      assert_match(/outcome:\s+ok/, output)
    end
  end

  # The case the whole command exists for.
  test "an unreachable document reports it, names egress, and exits non-zero" do
    stub_class_method(Hitch::ClientIdMetadata::Fetcher, :call, ->(_id, *) { CIMD::HOST_FAILURE }) do
      output, status = invoke(DOC_URL)
      assert_equal 1, status
      assert_match(/outcome:\s+unreachable/, output)
      assert_match(/egress/, output)
    end
  end

  # This is the regression: the documented "verify before you enable it"
  # flow ran with the flag still false, and the task exited 1 without a
  # single packet leaving the host.
  test "the probe runs with CIMD disabled, which is when an operator uses it" do
    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])
    reached = false

    stub_class_method(Hitch::ClientIdMetadata::Fetcher, :call, ->(_id, *) { reached = true; [ document, 3600 ] }) do
      output, status = invoke(DOC_URL)
      assert reached, "the task must attempt the fetch even while the feature is off"
      assert_nil status
      assert_match(/outcome:\s+ok/, output)
    end
  end
end
