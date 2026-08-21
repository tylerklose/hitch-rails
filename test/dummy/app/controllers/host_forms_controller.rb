# frozen_string_literal: true

# Test-only host endpoint that deliberately shadows Hitch's token path when a
# request header activates its route constraint. Ordinary form parameters must
# survive Hitch's earlier middleware unchanged.
class HostFormsController < ApplicationController
  skip_forgery_protection

  def create
    render json: request.request_parameters
  end
end
