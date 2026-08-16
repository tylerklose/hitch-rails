# frozen_string_literal: true

require "json"

module HitchPackageDistribution
  DECISION_PATH = "docs/evidence/0.2.0/release/pre4-publication-decision.json"

  module_function

  def resolve(root:, declared:, development:)
    return "internal_only" if development
    return declared unless declared == "public_if_pre4_published"

    path = File.join(root, DECISION_PATH)
    decision = JSON.parse(File.binread(path), allow_duplicate_key: false).fetch("decision")
    case decision
    when "deferred_to_final" then "internal_only"
    when "published_pre4" then "public_eligible"
    else raise "pre4 publication decision is invalid"
    end
  rescue Errno::ENOENT, JSON::ParserError, KeyError => error
    raise "pre4 publication decision cannot resolve conditional distribution: #{error.class}"
  end
end
