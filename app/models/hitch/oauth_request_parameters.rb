# frozen_string_literal: true

module Hitch
  class OauthRequestParameters
    # Deliberately not an ArgumentError: the rescue below converts decoding
    # ArgumentErrors into Invalid, and must never catch its own product.
    class Invalid < StandardError; end

    FORM_MEDIA_TYPE = "application/x-www-form-urlencoded"

    def initialize(request, allowed:, form_only: false)
      @request = request
      @allowed = allowed.map(&:to_s).freeze
      @form_only = form_only
    end

    def to_h
      query = query_pairs
      reject_query_security_parameters!(query) if form_only
      pairs = (form_only ? [] : query) + form_pairs
      reject_nested_security_parameters!(pairs)

      allowed.to_h do |name|
        values = pairs.filter_map { |key, value| value if key == name }
        raise Invalid, "#{name} must not be repeated" if values.length > 1
        raise Invalid, "#{name} must be a string" if values.any? { |value| !value.is_a?(String) }
        raise Invalid, "#{name} must not be blank" if values.one? && values.first.blank?

        [ name.to_sym, values.first&.dup&.freeze ]
      end.freeze
    rescue ArgumentError
      raise Invalid, "OAuth parameters are not valid form encoding"
    end

    private

    attr_reader :request, :allowed, :form_only

    def query_pairs
      decode(request.query_string)
    end

    def form_pairs
      return [] unless request.post? && request.media_type == FORM_MEDIA_TYPE

      decode(request.raw_post)
    end

    def decode(value)
      return [] if value.blank?

      URI.decode_www_form(value)
    end

    def reject_nested_security_parameters!(pairs)
      pairs.each do |key, _value|
        root = key.to_s.split("[", 2).first
        next unless allowed.include?(root)
        next if key == root

        raise Invalid, "#{root} must be a scalar string"
      end
    end

    def reject_query_security_parameters!(pairs)
      pairs.each do |key, _value|
        root = key.to_s.split("[", 2).first
        next unless allowed.include?(root)

        raise Invalid, "#{root} must be sent in the form body"
      end
    end
  end
end
