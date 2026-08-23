# frozen_string_literal: true

# A non-human principal. Hitch takes any persisted record, so an agent holds
# its own account rather than borrowing a person's — see the README's
# "Agents as principals".
class Agent < ApplicationRecord
  has_many :access_tokens,
    class_name: "Hitch::AccessToken",
    as: :principal,
    dependent: :destroy

  before_validation(on: :create) { self.id ||= SecureRandom.uuid }

  validates :id, presence: true
  validates :name, presence: true, uniqueness: true
end
