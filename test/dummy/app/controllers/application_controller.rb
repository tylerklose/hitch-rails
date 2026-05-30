# frozen_string_literal: true

class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  # Minimal session-auth shim so integration tests can drive the
  # gem's authorize flow as a "signed-in" user. Real host apps will
  # have their own current_user — the gem only requires the method
  # exists and returns the principal record (or nil).
  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end
  helper_method :current_user
end
