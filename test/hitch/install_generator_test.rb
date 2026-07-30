# frozen_string_literal: true

require "test_helper"

# The generated initializer is where new installations become
# spec-conformant: MCP 2026-07-28 makes supporting Client ID Metadata
# Documents a SHOULD, and clients read
# `client_id_metadata_document_supported` to choose it over the
# deprecated Dynamic Client Registration. Nothing else in the suite
# covers that file, so the line could have vanished with CI green.
class Hitch::InstallGeneratorTest < ActiveSupport::TestCase
  TEMPLATE = File.expand_path("../../lib/generators/hitch/install/templates/initializer.rb", __dir__)

  def template = @template ||= File.read(TEMPLATE)

  test "the generated initializer opts new installations into CIMD" do
    assert_match(/^\s*config\.client_id_metadata_enabled = true$/, template,
                 "new installs are how CIMD reaches the spec's SHOULD, since the library fallback stays false")
  end

  test "it explains the egress requirement, which is the reason this is not a library default" do
    assert_match(/http_proxy/, template,
                 "a host behind a proxy would advertise support it cannot deliver — say so where it is configured")
    assert_match(/hitch:cimd:check/, template,
                 "point at the way to verify egress rather than asking operators to guess")
  end

  test "the library fallback stays false, so upgrading changes nothing" do
    Hitch.reset_configuration!
    assert_equal false, Hitch.configuration.client_id_metadata_enabled
  ensure
    Hitch.reset_configuration!
  end

  test "it is valid Ruby" do
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(template) }
  end
end
