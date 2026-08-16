# frozen_string_literal: true

require "time"

module HitchDownloadedRelease
  class VerificationError < StandardError; end

  module_function

  def reconcile!(accepted:, live:)
    unless accepted.is_a?(Hash) && live.is_a?(Hash)
      raise VerificationError, "downloaded release evidence must be objects"
    end
    unless iso8601?(live["verified_at"])
      raise VerificationError, "live downloaded release needs an ISO-8601 verification time"
    end

    accepted_immutable = accepted.reject { |key, _value| key == "verified_at" }
    live_immutable = live.reject { |key, _value| key == "verified_at" }
    return true if live_immutable == accepted_immutable

    paths = changed_paths(accepted_immutable, live_immutable)
    raise VerificationError,
      "live downloaded release differs from accepted evidence at: #{paths.join(', ')}"
  end

  def changed_paths(expected, actual, prefix = nil)
    if expected.is_a?(Hash) && actual.is_a?(Hash)
      (expected.keys | actual.keys).sort.flat_map do |key|
        path = [ prefix, key ].compact.join(".")
        changed_paths(expected[key], actual[key], path)
      end
    elsif expected == actual
      []
    else
      [ prefix || "root" ]
    end
  end
  private_class_method :changed_paths

  def iso8601?(value)
    value.is_a?(String) && Time.iso8601(value)
  rescue ArgumentError
    false
  end
  private_class_method :iso8601?
end
