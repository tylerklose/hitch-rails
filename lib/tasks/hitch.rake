# frozen_string_literal: true

require "hitch/doctor"

module Hitch
  module ClientCredentialTask
    module_function

    def disclose(stdin: $stdin, tty_path: "/dev/tty")
      with_output(stdin: stdin, tty_path: tty_path) do |output|
        Hitch::Client.transaction do
          credentials = yield
          output.write(
            "client_id=#{credentials.client.client_id}\n" \
            "client_secret=#{credentials.client_secret}\n"
          )
          output.flush
        end
      end
    end

    def with_output(stdin:, tty_path:)
      output_path = ENV["OUTPUT_FILE"].presence
      if output_path
        with_exclusive_file(output_path) { |output| yield output }
      elsif stdin.tty?
        File.open(tty_path, File::WRONLY) { |output| yield output }
      else
        abort "Set OUTPUT_FILE when standard input is not an interactive terminal"
      end
    end

    def with_exclusive_file(path)
      output = File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      begin
        output.chmod(0o600)
        yield output
      rescue Exception # rubocop:disable Lint/RescueException -- remove a partially written credential file on every task abort
        output.close
        File.unlink(path) if File.exist?(path)
        raise
      ensure
        output.close unless output.closed?
      end
    rescue Errno::EEXIST
      abort "Refusing to overwrite existing OUTPUT_FILE"
    end
  end

  private_constant :ClientCredentialTask
end

namespace :hitch do
  desc "Diagnose Hitch configuration, routes, schema, registry, admission store, and package contents"
  task doctor: :environment do
    doctor = Hitch.const_get(:Doctor, false)
    format = ENV.fetch("HITCH_DOCTOR_FORMAT", "human")
    report = doctor.call
    puts doctor.render(report, format:)
    exit(1) if report.failure?
  rescue ArgumentError => error
    abort error.message
  end

  namespace :clients do
    desc "Create a confidential OAuth client and disclose its one-time secret safely"
    task create_confidential: :environment do
      client_id = ENV["CLIENT_ID"].presence || abort("CLIENT_ID is required")
      redirect_uri = ENV["REDIRECT_URI"].presence || abort("REDIRECT_URI is required")

      Hitch.const_get(:ClientCredentialTask, false).disclose do
        Hitch::Client.register_confidential!(
          client_id: client_id,
          client_name: ENV["NAME"],
          redirect_uris: [ redirect_uri ]
        )
      end
    end

    desc "Rotate a confidential OAuth client's secret and disclose it safely"
    task rotate_secret: :environment do
      client_id = ENV["CLIENT_ID"].presence || abort("CLIENT_ID is required")

      Hitch.const_get(:ClientCredentialTask, false).disclose do
        client = Hitch::Client.find_by(client_id: client_id)
        abort "Confidential client not found" unless client&.confidential_client?

        client.rotate_secret!
      end
    end
  end

  namespace :cimd do
    desc "Fetch a Client ID Metadata Document to verify this host's egress " \
         "(usage: bin/rails 'hitch:cimd:check[https://client.example/client.json]')"
    task :check, [ :client_id ] => :environment do |_task, args|
      client_id = args[:client_id]
      abort "Usage: bin/rails 'hitch:cimd:check[https://client.example/client.json]'" if client_id.blank?

      # Reports; never changes what discovery advertises. Whether this
      # host can reach one document today is a different question from
      # whether it supports CIMD, and only the second belongs in the
      # discovery document.
      result = Hitch::ClientIdMetadata.diagnose(client_id)

      puts "client_id: #{client_id}"
      puts "outcome:   #{result.outcome}"
      puts "detail:    #{result.detail}"
      puts
      puts(result.ok? ? "Egress to this document works." : "This host could not resolve that document.")
      exit(1) unless result.ok?
    end
  end
end
