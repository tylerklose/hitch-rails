# frozen_string_literal: true

require "test_helper"

# Unit test for Hitch::ApplicationController#current_principal resolution.
#
# Rails 8's built-in `bin/rails g authentication` exposes the signed-in
# user as Current.user and defines NO current_user controller method —
# but current_user is the gem's default principal_method. Without a
# fallback, a stock Rails 8 auth app would treat every visitor as
# unauthenticated and the consent screen would never render (verified
# end-to-end against a real canary app). current_principal therefore
# falls back to Current.user when the configured principal_method isn't
# defined on the controller.
#
# Tested directly on the controller instance (no request cycle) so the
# resolution logic is pinned deterministically.
class CurrentPrincipalTest < ActiveSupport::TestCase
  setup do
    User.delete_all
    Hitch.reset_configuration!
    @user = User.create!(email: "principal@test")
  end

  teardown do
    Current.user = nil
    Hitch.reset_configuration!
  end

  test "falls back to Current.user when principal_method is not defined (Rails 8 auth)" do
    Hitch.configure { |c| c.principal_method = :method_the_host_does_not_define }
    Current.user = @user

    assert_equal @user, Hitch::ApplicationController.new.current_principal
  end

  test "returns nil when principal_method is undefined and Current.user is nil" do
    Hitch.configure { |c| c.principal_method = :method_the_host_does_not_define }
    Current.user = nil

    assert_nil Hitch::ApplicationController.new.current_principal
  end

  test "prefers the configured principal_method when the host defines it" do
    Hitch.configure { |c| c.principal_method = :current_user }
    controller = Hitch::ApplicationController.new
    controller.define_singleton_method(:current_user) { "user-from-method" }
    Current.user = @user # must be ignored in favor of the method

    assert_equal "user-from-method", controller.current_principal
  end

  # Rails 8 auth populates Current.user inside resume_session, which
  # normally runs in the require_authentication before_action the gem
  # skips. current_principal must call resume_session itself before
  # reading Current.user — otherwise a signed-in user looks logged out and
  # the consent screen loops back to login.
  test "calls resume_session before reading Current.user when available" do
    Hitch.configure { |c| c.principal_method = :method_the_host_does_not_define }
    controller = Hitch::ApplicationController.new
    resumed = false
    controller.define_singleton_method(:resume_session) do
      resumed = true
      Current.user = User.first # mimic Rails 8 resume_session populating it
    end

    principal = controller.current_principal

    assert resumed, "current_principal must invoke resume_session"
    assert_equal @user, principal, "Current.user set by resume_session must be returned"
  end
end
