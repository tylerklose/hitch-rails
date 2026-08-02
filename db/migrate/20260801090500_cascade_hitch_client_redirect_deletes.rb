# frozen_string_literal: true

class CascadeHitchClientRedirectDeletes < ActiveRecord::Migration[7.1]
  def up
    return unless table_exists?(:hitch_client_redirect_uris) && table_exists?(:hitch_clients)
    return if redirect_foreign_key&.options&.fetch(:on_delete, nil) == :cascade

    remove_foreign_key :hitch_client_redirect_uris,
      column: :hitch_client_id,
      if_exists: true
    add_foreign_key :hitch_client_redirect_uris,
      :hitch_clients,
      column: :hitch_client_id,
      on_delete: :cascade
  end

  def down
    return unless table_exists?(:hitch_client_redirect_uris) && table_exists?(:hitch_clients)
    return unless redirect_foreign_key&.options&.fetch(:on_delete, nil) == :cascade

    remove_foreign_key :hitch_client_redirect_uris,
      column: :hitch_client_id,
      if_exists: true
    add_foreign_key :hitch_client_redirect_uris,
      :hitch_clients,
      column: :hitch_client_id
  end


  private

  def redirect_foreign_key
    connection.foreign_keys(:hitch_client_redirect_uris).find do |foreign_key|
      foreign_key.to_table == "hitch_clients" && foreign_key.options[:column].to_s == "hitch_client_id"
    end
  end
end
