# frozen_string_literal: true

# Test-only sign-in shim — integration tests POST here to set
# session[:user_id] before driving the OAuth dance.
class SignInsController < ApplicationController
  skip_forgery_protection

  def create
    session[:user_id] = params[:user_id]
    head :ok
  end
end
