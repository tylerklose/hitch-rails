# frozen_string_literal: true

# Mirrors the Rails 8 built-in authentication generator, which exposes
# the signed-in user as Current.user (and defines NO current_user
# controller method). Lets the suite exercise Hitch's Current.user
# fallback in current_principal.
class Current < ActiveSupport::CurrentAttributes
  attribute :user
end
