# frozen_string_literal: true

module HitchExclusiveReport
  module_function

  def write!(root:, path:, bytes:, variable:)
    expanded = File.expand_path(path)
    parent = File.realpath(File.dirname(expanded))
    repository = File.realpath(root)
    destination = File.join(parent, File.basename(expanded))
    if destination == repository || destination.start_with?("#{repository}/")
      raise ArgumentError,
        "#{variable} must resolve outside the repository so verification stays read-only"
    end

    File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
    end
    destination
  rescue Errno::ENOENT
    raise ArgumentError, "#{variable} parent directory must already exist"
  rescue Errno::EEXIST
    raise ArgumentError, "#{variable} destination must not already exist"
  end
end
