# frozen_string_literal: true

# A second principal type for the dummy, keyed on a string rather than an
# integer. Hitch stores principal_id as a string so a host may key principals
# on integer, UUID, or ULID; nothing exercised a non-integer key until this
# table existed.
class CreateAgents < ActiveRecord::Migration[8.0]
  def change
    create_table :agents, id: :string do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :agents, :name, unique: true
  end
end
