# frozen_string_literal: true

class User < ApplicationRecord
  has_many :access_tokens,
    class_name: "Hitch::AccessToken",
    as: :principal,
    dependent: :destroy

  validates :email, presence: true, uniqueness: true
end
