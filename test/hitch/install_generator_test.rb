# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/hitch/install/install_generator"

# Runs the generator into a temporary destination and inspects what it
# emitted, rather than reading the template. Reading the template proves
# the file on disk says the right thing; it proves nothing about whether
# the generator still copies it, or copies that one.
#
# This is where new installations become spec-conformant: MCP 2026-07-28
# makes supporting Client ID Metadata Documents a SHOULD, and clients
# read `client_id_metadata_document_supported` to choose it over the
# deprecated Dynamic Client Registration. The library fallback stays
# false, so this file is the whole mechanism.
class Hitch::InstallGeneratorTest < Rails::Generators::TestCase
  tests Hitch::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  setup do
    # The generator appends the engine mount to an existing routes file.
    mkdir_p("#{destination_root}/config")
    File.write("#{destination_root}/config/routes.rb", "Rails.application.routes.draw do\nend\n")
  end

  def generated_initializer
    File.read("#{destination_root}/config/initializers/hitch.rb")
  end

  test "the generated initializer opts new installations into CIMD" do
    run_generator
    assert_file "config/initializers/hitch.rb"
    assert_match(/^\s*config\.client_id_metadata_enabled = true$/, generated_initializer,
                 "new installs are how CIMD reaches the spec's SHOULD, since the library fallback stays false")
  end

  test "it explains the egress requirement, which is why this is not a library default" do
    run_generator
    assert_match(/http_proxy/, generated_initializer,
                 "a host behind a proxy would advertise support it cannot deliver — say so where it is configured")
    assert_match(/hitch:cimd:check/, generated_initializer,
                 "point at the way to verify egress rather than asking operators to guess")
  end

  test "what it emits is valid Ruby that configures Hitch" do
    run_generator
    assert_nothing_raised { RubyVM::AbstractSyntaxTree.parse(generated_initializer) }
    assert_match(/Hitch\.configure do \|config\|/, generated_initializer)
  end

  test "it mounts the engine" do
    run_generator
    assert_file "config/routes.rb", /mount Hitch::Engine/
  end

  test "the library fallback stays false, so upgrading changes nothing" do
    Hitch.reset_configuration!
    assert_equal false, Hitch.configuration.client_id_metadata_enabled
  ensure
    Hitch.reset_configuration!
  end
end
