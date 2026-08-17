# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Shared recursive helpers for the JSON-value structures that cross MCP
      # boundaries. Keys are never symbolized (INV-MCP-007).
      module JsonValues
        # Every rejecting boundary supplies its own on_invalid; this fires only
        # when a policy rejects without one.
        DEFAULT_HANDLER = lambda do |reason, _detail|
          raise ArgumentError, "JSON value copy rejected (#{reason})"
        end

        module_function

        # String/Symbol-indifferent read that prefers the key exactly as given.
        def read(hash, key)
          return unless hash.is_a?(Hash)
          return hash[key] if hash.key?(key)

          hash[key.is_a?(Symbol) ? key.to_s : key.to_sym]
        end

        # The one deep JSON copier. Each boundary states its policy:
        #   keys:       :as_is, :string (String only), :stringify_symbols,
        #               :preserve (String copied, Symbol kept), or :to_s
        #   symbols:    Symbol values — :keep, :to_s, or :reject
        #   foreign:    values outside the JSON universe — :keep or :reject
        #   finite:     reject non-finite Floats
        #   duplicates: keys that collide after normalization — :replace or :reject
        #   freeze:     deep-freeze the copy
        #   max_depth / max_objects: structural caps
        # on_invalid receives (reason, detail) and either raises or returns the
        # replacement for the entire copy. Reasons: :recursive, :depth,
        # :objects, :key, :duplicate_key, :non_finite, :foreign.
        def copy(value, keys: :as_is, symbols: :keep, foreign: :keep, finite: false,
          duplicates: :replace, freeze: false, max_depth: nil, max_objects: nil,
          on_invalid: DEFAULT_HANDLER)
          Copier.new(
            keys:, symbols:, foreign:, finite:, duplicates:,
            freeze:, max_depth:, max_objects:, on_invalid:
          ).call(value)
        end

        def deep_string_copy_and_freeze(value)
          copy(value, keys: :to_s, freeze: true)
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, child| deep_freeze(key); deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          end
          value.freeze
        end

        class Copier
          REPLACED = Object.new
          private_constant :REPLACED

          def initialize(**policy)
            @policy = policy
            @seen = {}
            @objects = 0
          end

          def call(value)
            catch(REPLACED) { walk(value, 1) }
          end

          private

          def walk(value, depth)
            max_depth = @policy[:max_depth]
            invalid!(:depth, nil) if max_depth && depth > max_depth

            copied = case value
            when Hash then walk_hash(value, depth)
            when Array then walk_array(value, depth)
            when String then value.dup
            when Symbol then symbol_value(value)
            when Float
              invalid!(:non_finite, nil) if @policy[:finite] && !value.finite?

              value
            when Integer, TrueClass, FalseClass, NilClass
              value
            else
              invalid!(:foreign, nil) if @policy[:foreign] == :reject

              value
            end
            @policy[:freeze] ? copied.freeze : copied
          end

          def walk_hash(hash, depth)
            invalid!(:recursive, nil) if @seen.key?(hash.object_id)

            @objects += 1
            max_objects = @policy[:max_objects]
            invalid!(:objects, nil) if max_objects && @objects > max_objects

            @seen[hash.object_id] = true
            hash.each_with_object({}) do |(key, child), result|
              copied_key = copy_key(key)
              invalid!(:duplicate_key, copied_key) if @policy[:duplicates] == :reject && result.key?(copied_key)

              result[copied_key] = walk(child, depth + 1)
            end
          ensure
            @seen.delete(hash.object_id)
          end

          def walk_array(array, depth)
            invalid!(:recursive, nil) if @seen.key?(array.object_id)

            @seen[array.object_id] = true
            array.map { |child| walk(child, depth + 1) }
          ensure
            @seen.delete(array.object_id)
          end

          def copy_key(key)
            case @policy[:keys]
            when :as_is then key
            when :to_s then key.to_s.freeze
            when :string
              invalid!(:key, key) unless key.is_a?(String)

              key.dup.freeze
            when :stringify_symbols
              case key
              when String then key.dup.freeze
              when Symbol then key.to_s.freeze
              else invalid!(:key, key)
              end
            when :preserve
              case key
              when String then key.dup.freeze
              when Symbol then key
              else invalid!(:key, key)
              end
            end
          end

          def symbol_value(value)
            case @policy[:symbols]
            when :keep then value
            when :to_s then value.to_s
            else invalid!(:foreign, nil)
            end
          end

          def invalid!(reason, detail)
            throw REPLACED, @policy[:on_invalid].call(reason, detail)
          end
        end
      end
    end
  end
end
