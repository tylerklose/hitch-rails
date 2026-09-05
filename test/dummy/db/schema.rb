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

ActiveRecord::Schema[7.2].define(version: 2026_08_24_000002) do
  create_table "agents", id: :string, force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_agents_on_name", unique: true
  end

  create_table "hitch_access_tokens", force: :cascade do |t|
    t.string "principal_type", null: false
    t.string "principal_id", null: false
    t.string "client_id", null: false
    t.string "client_name"
    t.string "authorization_code_digest"
    t.datetime "code_expires_at"
    t.string "redirect_uri"
    t.string "code_challenge", null: false
    t.string "code_challenge_method", default: "S256", null: false
    t.string "token_digest"
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.string "resource_uri"
    t.string "scopes", default: "mcp", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "refresh_token_digest"
    t.datetime "refresh_expires_at"
    t.datetime "refresh_consumed_at"
    t.string "family_id"
    t.datetime "family_expires_at"
    t.index ["authorization_code_digest"], name: "index_hitch_access_tokens_on_authorization_code_digest", unique: true, where: "authorization_code_digest IS NOT NULL"
    t.index ["family_id"], name: "index_hitch_access_tokens_on_family_id", where: "family_id IS NOT NULL"
    t.index ["principal_type", "principal_id"], name: "index_hitch_access_tokens_on_principal"
    t.index ["refresh_token_digest"], name: "index_hitch_access_tokens_on_refresh_token_digest", unique: true, where: "refresh_token_digest IS NOT NULL"
    t.index ["token_digest"], name: "index_hitch_access_tokens_on_token_digest", unique: true, where: "token_digest IS NOT NULL"
  end

  create_table "hitch_client_redirect_uris", force: :cascade do |t|
    t.integer "hitch_client_id", null: false
    t.string "uri", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hitch_client_id", "uri"], name: "index_hitch_client_redirect_uris_on_client_and_uri", unique: true
  end

  create_table "hitch_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_name", null: false
    t.string "application_type"
    t.string "token_endpoint_auth_method", default: "none", null: false
    t.string "client_secret_digest"
    t.datetime "client_secret_issued_at"
    t.datetime "client_secret_rotated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "operator_registered", default: false, null: false
    t.index ["client_id"], name: "index_hitch_clients_on_client_id", unique: true
    t.check_constraint "(token_endpoint_auth_method = 'none' AND client_secret_digest IS NULL AND client_secret_issued_at IS NULL AND client_secret_rotated_at IS NULL) OR (token_endpoint_auth_method = 'client_secret_basic' AND client_secret_digest IS NOT NULL AND client_secret_issued_at IS NOT NULL)", name: "hitch_clients_secret_consistency_check"
    t.check_constraint "operator_registered = FALSE OR token_endpoint_auth_method = 'client_secret_basic'", name: "hitch_clients_operator_registration_check"
    t.check_constraint "token_endpoint_auth_method IN ('none', 'client_secret_basic')", name: "hitch_clients_auth_method_check"
  end

  create_table "hitch_device_grants", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_name"
    t.string "device_code_digest"
    t.string "user_code_digest"
    t.string "principal_type"
    t.string "principal_id"
    t.string "scopes", default: "mcp", null: false
    t.string "resource_uri", null: false
    t.datetime "expires_at", null: false
    t.datetime "approved_at"
    t.datetime "denied_at"
    t.datetime "consumed_at"
    t.datetime "last_polled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "token_endpoint_auth_method", null: false
    t.index ["device_code_digest"], name: "index_hitch_device_grants_on_device_code_digest", unique: true, where: "device_code_digest IS NOT NULL"
    t.index ["expires_at"], name: "index_hitch_device_grants_on_expires_at"
    t.index ["user_code_digest"], name: "index_hitch_device_grants_on_user_code_digest", unique: true, where: "user_code_digest IS NOT NULL"
    t.check_constraint "(approved_at IS NULL AND principal_type IS NULL AND principal_id IS NULL) OR (approved_at IS NOT NULL AND principal_type IS NOT NULL AND principal_id IS NOT NULL)", name: "hitch_device_grants_principal_check"
    t.check_constraint "NOT (approved_at IS NOT NULL AND denied_at IS NOT NULL)", name: "hitch_device_grants_decision_check"
    t.check_constraint "consumed_at IS NULL OR approved_at IS NOT NULL", name: "hitch_device_grants_consumption_check"
    t.check_constraint "token_endpoint_auth_method IN ('none', 'client_secret_basic')", name: "hitch_device_grants_auth_method_check"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "hitch_client_redirect_uris", "hitch_clients", on_delete: :cascade
end
