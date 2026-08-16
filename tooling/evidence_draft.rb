# frozen_string_literal: true

require "json"
require "time"

module HitchEvidenceDraft
  ROOT = File.expand_path("..", __dir__)
  TEMPLATE_ROOT = "docs/evidence_templates/0.2.0"
  MAX_BYTES = 1_048_576
  KINDS = {
    "copied_lineage" => [ "copied-lineage.json", "hitch.m6-copied-lineage-adoption.v1", "M6" ],
    "independent" => [ "independent.json", "hitch.m7-independent-adoption.v1", "M7" ],
    "product_clients" => [ "product-smokes.json", "hitch.m8-product-client-evidence.v1", "M8" ],
    "hosted_matrix" => [ "hosted-matrix.json", "hitch.m8-hosted-matrix.v1", "M8" ],
    "final_local_gates" => [ "final-local-gates.json", "hitch.m8-final-local-gates.v1", "M8" ],
    "final_check" => [ "final-check.json", "hitch.m8-final-check.v1", "M8" ],
    "publication_authority" => [ "final-publication-authority.json", "hitch.m8-publication-authority.v1", "M8" ],
    "downloaded_gem" => [ "downloaded-gem.json", "hitch.m8-downloaded-gem.v1", "M8" ]
  }.freeze
  PLACEHOLDER = /\A<(?<type>[a-z0-9_-]+):(?<label>[^>]+)>\z/
  SHA256 = /\A[0-9a-f]{64}\z/
  COMMIT = /\A[0-9a-f]{40}\z/

  class VerificationError < StandardError; end

  module_function

  def validate!(kind:, path:, ready: false, root: ROOT)
    filename, schema, milestone = KINDS.fetch(kind) do
      raise VerificationError, "unknown evidence kind #{kind.inspect}; choose #{KINDS.keys.join(', ')}"
    end
    template = parse!(File.join(root, TEMPLATE_ROOT, filename), "#{kind} template")
    candidate = parse!(path, path)
    errors = shape_errors(template, candidate, kind, ready:)
    errors << "#{kind}.schema must be #{schema}" unless candidate["schema"] == schema
    errors << "#{kind}.milestone must be #{milestone}" unless candidate["milestone"] == milestone
    if ready
      placeholders = placeholder_paths(candidate, kind)
      errors << "unreplaced placeholders: #{placeholders.join(', ')}" if placeholders.any?
      errors << "#{kind}.status may not remain draft" if candidate["status"] == "draft"
      errors.concat(ready_cardinality_errors(kind, candidate))
    end
    raise VerificationError, errors.uniq.join("\n") if errors.any?

    { "kind" => kind, "ready" => ready, "placeholders" => placeholder_paths(candidate, kind).length }.freeze
  end

  def ready_cardinality_errors(kind, candidate)
    return [] unless kind == "copied_lineage"

    operations = candidate.dig("benchmark", "operations")
    return [ "copied_lineage.benchmark.operations must contain exactly tools/list and tools/call" ] unless
      operations.is_a?(Array) && operations.map { |operation| operation["name"] } == %w[tools/list tools/call]

    operations.each_with_index.flat_map do |operation, offset|
      %w[old_runs new_runs].filter_map do |runs|
        next if operation[runs].is_a?(Array) && operation[runs].length == 5

        "copied_lineage.benchmark.operations[#{offset}].#{runs} must contain exactly five runs"
      end
    end
  end
  private_class_method :ready_cardinality_errors

  def parse!(path, label)
    raise VerificationError, "#{label} must be a regular file" unless File.file?(path) && !File.symlink?(path)
    raise VerificationError, "#{label} exceeds #{MAX_BYTES} bytes" if File.size(path) > MAX_BYTES

    value = JSON.parse(File.binread(path), allow_duplicate_key: false)
    raise VerificationError, "#{label} must contain an object" unless value.is_a?(Hash)

    value
  rescue Errno::ENOENT, JSON::ParserError => error
    raise VerificationError, "#{label} is invalid: #{error.message}"
  end

  def shape_errors(template, candidate, path, ready:)
    if template.is_a?(Hash)
      return [ "#{path} must be an object" ] unless candidate.is_a?(Hash)

      errors = []
      errors << "#{path} fields must be exactly #{template.keys.join(', ')}" unless
        candidate.keys.sort == template.keys.sort
      template.each do |key, child|
        errors.concat(shape_errors(child, candidate[key], "#{path}.#{key}", ready:)) if candidate.key?(key)
      end
      errors
    elsif template.is_a?(Array)
      return [ "#{path} must be an array" ] unless candidate.is_a?(Array)
      return [] if template.empty?
      if template.length == 1
        candidate.each_with_index.flat_map do |item, offset|
          shape_errors(template.first, item, "#{path}[#{offset}]", ready:)
        end
      else
        errors = []
        errors << "#{path} must contain exactly #{template.length} items" unless candidate.length == template.length
        template.each_with_index do |item, offset|
          errors.concat(shape_errors(item, candidate[offset], "#{path}[#{offset}]", ready:)) if candidate.length > offset
        end
        errors
      end
    elsif (match = template.is_a?(String) && PLACEHOLDER.match(template))
      placeholder_errors(match[:type], candidate, path, ready:)
    elsif candidate == template
      []
    else
      [ "#{path} must equal #{template.inspect}" ]
    end
  end
  private_class_method :shape_errors

  def placeholder_errors(type, value, path, ready:)
    return [] if !ready && value.is_a?(String) && PLACEHOLDER.match?(value)

    valid = case type
    when "string", "path", "command", "url" then value.is_a?(String) && !value.empty?
    when "sha256" then value.is_a?(String) && SHA256.match?(value)
    when "commit" then value.is_a?(String) && COMMIT.match?(value)
    when "timestamp"
      value.is_a?(String) && Time.iso8601(value)
    when "integer" then value.is_a?(Integer)
    when "positive-integer" then value.is_a?(Integer) && value.positive?
    when "number" then value.is_a?(Numeric)
    when "boolean" then value == true || value == false
    when "nullable-string" then value.nil? || value.is_a?(String)
    when "nullable-command", "nullable-path", "nullable-url"
      value.nil? || (value.is_a?(String) && !value.empty?)
    when "nullable-sha256" then value.nil? || (value.is_a?(String) && SHA256.match?(value))
    when "nullable-commit" then value.nil? || (value.is_a?(String) && COMMIT.match?(value))
    when "nullable-timestamp" then value.nil? || (value.is_a?(String) && Time.iso8601(value))
    else false
    end
    valid ? [] : [ "#{path} must replace the #{type} placeholder with the matching type" ]
  rescue ArgumentError
    [ "#{path} must replace the timestamp placeholder with ISO-8601" ]
  end
  private_class_method :placeholder_errors

  def placeholder_paths(value, path = nil)
    case value
    when Hash
      value.flat_map { |key, child| placeholder_paths(child, [ path, key ].compact.join(".")) }
    when Array
      value.each_with_index.flat_map { |child, offset| placeholder_paths(child, "#{path}[#{offset}]") }
    when String
      PLACEHOLDER.match?(value) ? [ path || "root" ] : []
    else
      []
    end
  end
  private_class_method :placeholder_paths
end
