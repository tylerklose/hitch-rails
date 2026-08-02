# frozen_string_literal: true

module Hitch
  class SchemaState < ApplicationRecord
    self.table_name = "hitch_schema_states"

    REDIRECT_URIS_KEY = "redirect_uris"

    class CorruptState < StandardError; end
    class TransitionConflict < StandardError; end

    validates :key, presence: true, uniqueness: true
    validates :version, inclusion: { in: [ 1, 2 ] }

    def self.redirect_uris_version
      on_primary do
        uncached { redirect_uris_state!.version }
      end
    end

    def self.transition_redirect_uris!(from:, to:)
      unless [ from, to ].sort == [ 1, 2 ]
        raise ArgumentError, "redirect authority transitions must be between versions 1 and 2"
      end

      on_primary do
        transaction do
          state = uncached { redirect_uris_state!(lock: true) }

          if state.version == to
            to
          elsif state.version != from
            raise CorruptState,
              "redirect URI authority is version #{state.version}; expected #{from} or #{to}"
          else
            yield

            changed = where(id: state.id, version: from).update_all(
              version: to,
              updated_at: Time.current
            )
            unless changed == 1
              raise TransitionConflict, "redirect URI authority changed during transition"
            end

            to
          end
        end
      end
    end
    private_class_method :transition_redirect_uris!

    def self.on_primary(&block)
      ActiveRecord::Base.connected_to(role: :writing, &block)
    end
    private_class_method :on_primary

    def self.redirect_uris_state!(lock: false)
      raise CorruptState, "hitch_schema_states is missing" unless table_exists?

      relation = where(key: REDIRECT_URIS_KEY).limit(2)
      relation = relation.lock if lock
      rows = relation.to_a
      unless rows.one?
        raise CorruptState,
          "expected exactly one redirect URI authority row, found #{rows.length}"
      end

      state = rows.first
      return state if [ 1, 2 ].include?(state.version)

      raise CorruptState, "invalid redirect URI authority version #{state.version.inspect}"
    end
    private_class_method :redirect_uris_state!
  end
end
