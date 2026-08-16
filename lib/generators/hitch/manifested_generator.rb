# frozen_string_literal: true

require "digest"
require "json"

module Hitch
  module Generators
    # Shared plumbing for generators that write a rollback manifest and
    # refuse rather than guess when the destination has drifted. Including
    # generators define +refusal_subject+ and +manifest_path+.
    module ManifestedGenerator
      private

      def constant_collision?(name)
        return false unless Object.const_defined?(name, false)
        return true if File.expand_path(destination_root) == File.expand_path(Rails.root)

        source = Object.const_source_location(name, false)&.first
        source && File.expand_path(source).start_with?("#{File.expand_path(destination_root)}/")
      rescue NameError
        false
      end

      def destination_file?(relative_path)
        File.file?(destination_path(relative_path))
      end

      def destination_path(relative_path)
        File.expand_path(relative_path, destination_root)
      end

      def sha256(relative_path)
        Digest::SHA256.file(destination_path(relative_path)).hexdigest
      end

      def refuse!(operation, errors)
        raise ::Thor::Error, "#{refusal_subject} #{operation} refused:\n- #{errors.join("\n- ")}"
      end

      def load_manifest
        JSON.parse(File.binread(destination_path(manifest_path)))
      rescue Errno::ENOENT
        refuse!("rollback", [ "missing rollback manifest: #{manifest_path}" ])
      rescue JSON::ParserError
        refuse!("rollback", [ "rollback manifest is invalid JSON: #{manifest_path}" ])
      end
    end
  end
end
