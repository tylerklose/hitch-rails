# frozen_string_literal: true

# Hitch accepts any Active Record model as an OAuth principal. The original
# polymorphic reference used Rails' numeric default, which truncated UUID/ULID
# IDs on SQLite and rejected them on PostgreSQL. Widen the shared representation
# to a string; integer primary keys continue to round-trip through Rails' model
# type casting.
#
# PostgreSQL rewrites and locks hitch_access_tokens while changing the column
# type. Hitch 0.1 is unreleased, but an existing adopter should still schedule
# this migration in an ordinary low-traffic deploy window. SQLite rebuilds the
# table through Active Record's adapter implementation.
class StringifyHitchAccessTokenPrincipalIds < ActiveRecord::Migration[7.1]
  BIGINT_MIN = -9_223_372_036_854_775_808
  BIGINT_MAX = 9_223_372_036_854_775_807

  def up
    return unless principal_id_column
    return if principal_id_column.type == :string

    case connection.adapter_name
    when "PostgreSQL"
      change_column :hitch_access_tokens,
        :principal_id,
        :string,
        null: false,
        using: "principal_id::text"
    when "SQLite"
      change_column :hitch_access_tokens, :principal_id, :string, null: false
    else
      raise ActiveRecord::MigrationError,
        "Hitch principal ID migration supports only PostgreSQL and SQLite"
    end
  end

  def down
    return unless principal_id_column
    return unless principal_id_column.type == :string

    unless every_principal_id_fits_bigint?
      raise ActiveRecord::IrreversibleMigration,
        "hitch_access_tokens contains non-numeric principal IDs; reverting would corrupt principal authority"
    end

    case connection.adapter_name
    when "PostgreSQL"
      change_column :hitch_access_tokens,
        :principal_id,
        :bigint,
        null: false,
        using: "principal_id::bigint"
    when "SQLite"
      change_column :hitch_access_tokens, :principal_id, :bigint, null: false
    else
      raise ActiveRecord::MigrationError,
        "Hitch principal ID migration supports only PostgreSQL and SQLite"
    end
  end

  private

  def principal_id_column
    return unless table_exists?(:hitch_access_tokens)

    connection.columns(:hitch_access_tokens).find { |column| column.name == "principal_id" }
  end

  def every_principal_id_fits_bigint?
    invalid = case connection.adapter_name
    when "PostgreSQL"
      select_value(<<~SQL.squish)
        SELECT 1
        FROM hitch_access_tokens
        WHERE CASE
          WHEN principal_id ~ '^-?(0|[1-9][0-9]*)$'
            THEN principal_id::numeric NOT BETWEEN #{BIGINT_MIN} AND #{BIGINT_MAX}
          ELSE TRUE
        END
        LIMIT 1
      SQL
    when "SQLite"
      select_value(<<~SQL.squish)
        SELECT 1
        FROM hitch_access_tokens
        WHERE CAST(CAST(principal_id AS INTEGER) AS TEXT) <> principal_id
        LIMIT 1
      SQL
    else
      return false
    end

    invalid.nil?
  end
end
