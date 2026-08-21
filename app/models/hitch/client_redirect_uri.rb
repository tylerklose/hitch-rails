# frozen_string_literal: true

module Hitch
  class ClientRedirectUri < ApplicationRecord
    self.table_name = "hitch_client_redirect_uris"

    belongs_to :client,
      class_name: "Hitch::Client",
      foreign_key: :hitch_client_id,
      inverse_of: :redirect_uri_records

    validates :uri, presence: true, uniqueness: { scope: :hitch_client_id }
  end
end
