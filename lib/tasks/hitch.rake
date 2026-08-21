# frozen_string_literal: true

require "hitch/doctor"

module Hitch
  # Argument parsing for hitch:tokens:issue. Kept out of the task body so a
  # bad PRINCIPAL aborts with a sentence instead of a NameError.
  module TokenIssueTask
    module_function

    # rpartition, not split: a namespaced principal (Accounts::User:5) has
    # colons in the model half, and only the last one separates the id.
    def principal!(value)
      model_name, _, id = value.to_s.rpartition(":")
      abort "PRINCIPAL is required, as Model:id (for example User:1)" if model_name.blank? || id.blank?

      model = model_name.safe_constantize
      unless model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class?
        abort "PRINCIPAL model #{model_name} is not an Active Record model"
      end

      record = model.find(id)
      # PostgreSQL casts "12 34" to 12, so a typo would issue a token for
      # somebody else. Insist the id we were handed is the id we found.
      abort "PRINCIPAL id #{id.inspect} is not an exact id" unless record.id.to_s == id

      record
    rescue ActiveRecord::RecordNotFound
      abort "No #{model_name} with id #{id}"
    end

    # Long enough that a cron agent is not reissued monthly, short enough
    # that an unnoticed leak expires.
    def days!(value)
      return 90 if value.blank?

      days = Integer(value, exception: false)
      abort "EXPIRES_IN_DAYS must be a positive whole number of days" unless days&.positive?

      days
    end
  end

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

    def disclose_token(stdin: $stdin, tty_path: "/dev/tty")
      with_output(stdin: stdin, tty_path: tty_path) do |output|
        Hitch::AccessToken.transaction do
          output.write("access_token=#{yield}\n")
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
end

namespace :hitch do
  desc "Diagnose Hitch configuration, routes, schema, registry, and admission store"
  task doctor: :environment do
    format = ENV.fetch("HITCH_DOCTOR_FORMAT", "human")
    report = Hitch::Doctor.call
    puts Hitch::Doctor.render(report, format:)
    exit(1) if report.failure?
  rescue ArgumentError => error
    abort error.message
  end

  namespace :clients do
    desc "Create a confidential OAuth client and disclose its one-time secret safely"
    task create_confidential: :environment do
      client_id = ENV["CLIENT_ID"].presence || abort("CLIENT_ID is required")
      redirect_uri = ENV["REDIRECT_URI"].presence || abort("REDIRECT_URI is required")

      Hitch::ClientCredentialTask.disclose do
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

      Hitch::ClientCredentialTask.disclose do
        client = Hitch::Client.find_by(client_id: client_id)
        abort "Confidential client not found" unless client&.confidential_client?

        client.rotate_secret!
      end
    end
  end

  namespace :tokens do
    desc "Issue a long-lived access token for a headless agent " \
         "(usage: bin/rails hitch:tokens:issue PRINCIPAL=User:1)"
    task issue: :environment do
      principal = Hitch::TokenIssueTask.principal!(ENV["PRINCIPAL"])
      scopes = ENV["SCOPES"].to_s.split
      days = Hitch::TokenIssueTask.days!(ENV["EXPIRES_IN_DAYS"])

      Hitch::ClientCredentialTask.disclose_token do
        Hitch::AccessToken.issue!(
          principal: principal,
          client_id: ENV["CLIENT_ID"].presence || "hitch-cli",
          client_name: ENV["NAME"],
          scopes: scopes,
          expires_in: days * 86_400
        )
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
