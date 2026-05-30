# frozen_string_literal: true

module Hitch
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
