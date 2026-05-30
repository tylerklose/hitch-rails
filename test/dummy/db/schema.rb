# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_28_041652) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "hitch_access_tokens", force: :cascade do |t|
    t.string "authorization_code_digest"
    t.string "client_id", null: false
    t.string "client_name"
    t.string "code_challenge", null: false
    t.string "code_challenge_method", default: "S256", null: false
    t.datetime "code_expires_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.bigint "principal_id", null: false
    t.string "principal_type", null: false
    t.string "redirect_uri"
    t.string "resource_uri"
    t.datetime "revoked_at"
    t.string "scopes", default: "mcp", null: false
    t.string "token_digest"
    t.datetime "updated_at", null: false
    t.index ["authorization_code_digest"], name: "index_hitch_access_tokens_on_authorization_code_digest", unique: true, where: "(authorization_code_digest IS NOT NULL)"
    t.index ["principal_type", "principal_id"], name: "index_hitch_access_tokens_on_principal"
    t.index ["token_digest"], name: "index_hitch_access_tokens_on_token_digest", unique: true, where: "(token_digest IS NOT NULL)"
  end

  create_table "hitch_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_name", null: false
    t.datetime "created_at", null: false
    t.string "redirect_uris", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_hitch_clients_on_client_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end
end
