# frozen_string_literal: true

require "test_helper"
require "rake"
require "stringio"
require "tmpdir"

class HitchClientsTaskTest < ActiveSupport::TestCase
  CREATE_TASK = "hitch:clients:create_confidential"
  ROTATE_TASK = "hitch:clients:rotate_secret"

  class FailingWriter
    def write(*) = raise(Errno::ENOSPC)
    def flush = nil
    def close = nil
    def closed? = false
  end

  setup do
    Hitch::ClientRedirectUri.delete_all
    Hitch::Client.delete_all
    Rails.application.load_tasks unless Rake::Task.task_defined?(CREATE_TASK)
    @original_env = ENV.to_h
  end

  teardown do
    ENV.replace(@original_env)
    [ CREATE_TASK, ROTATE_TASK ].each do |name|
      Rake::Task[name].reenable if Rake::Task.task_defined?(name)
    end
  end

  test "create task writes one credential disclosure to a new 0600 file and never stdout" do
    Dir.mktmpdir("hitch-credentials") do |directory|
      output_path = File.join(directory, "client.credentials")
      configure_create(output_path, client_id: "deploy-bot")

      stdout, stderr = capture_io { invoke(CREATE_TASK) }

      assert_empty stdout
      assert_empty stderr
      assert_equal 0o600, File.stat(output_path).mode & 0o777
      secret = disclosed_secret(output_path)
      assert_equal 1, File.read(output_path).scan(secret).length
      client = Hitch::Client.find_by!(client_id: "deploy-bot")
      assert client.authenticates_secret?(secret)
      refute_includes client.attributes.values, secret
    end
  end

  test "create task refuses an existing output path before creating a client" do
    Dir.mktmpdir("hitch-credentials") do |directory|
      output_path = File.join(directory, "existing")
      File.write(output_path, "owned-by-operator")
      configure_create(output_path, client_id: "must-not-exist")

      error = assert_raises(SystemExit) { capture_io { invoke(CREATE_TASK) } }

      assert_equal 1, error.status
      assert_equal "owned-by-operator", File.read(output_path)
      refute Hitch::Client.exists?(client_id: "must-not-exist")
    end
  end

  test "noninteractive task requires OUTPUT_FILE and does not create a credential" do
    ENV.delete("OUTPUT_FILE")
    ENV["CLIENT_ID"] = "missing-output"
    ENV["NAME"] = "Missing Output"
    ENV["REDIRECT_URI"] = "https://client.test/callback"
    previous_stdin = $stdin
    $stdin = StringIO.new
    def $stdin.tty? = false

    stdout, _stderr = capture_io do
      assert_raises(SystemExit) { invoke(CREATE_TASK) }
    end

    assert_empty stdout
    refute Hitch::Client.exists?(client_id: "missing-output")
  ensure
    $stdin = previous_stdin
  end

  test "interactive disclosure writes only to the tty path" do
    Dir.mktmpdir("hitch-tty") do |directory|
      tty_path = File.join(directory, "tty")
      File.write(tty_path, "")
      fake_tty = StringIO.new
      def fake_tty.tty? = true
      credentials = Hitch::Client.register_confidential!(
        client_id: "interactive",
        client_name: "Interactive",
        redirect_uris: [ "https://client.test/callback" ]
      )
      ENV.delete("OUTPUT_FILE")
      task_writer = Hitch.const_get(:ClientCredentialTask, false)

      stdout, stderr = capture_io do
        task_writer.disclose(stdin: fake_tty, tty_path: tty_path) do
          "client_id=#{credentials.client.client_id}\nclient_secret=#{credentials.client_secret}\n"
        end
      end

      assert_empty stdout
      assert_empty stderr
      assert_equal 1, File.read(tty_path).scan(credentials.client_secret).length
    end
  end

  test "rotate task invalidates the old secret and discloses the replacement once" do
    original = Hitch::Client.register_confidential!(
      client_id: "rotating",
      client_name: "Rotating",
      redirect_uris: [ "https://client.test/callback" ]
    )

    Dir.mktmpdir("hitch-credentials") do |directory|
      output_path = File.join(directory, "rotated.credentials")
      ENV["CLIENT_ID"] = original.client.client_id
      ENV["OUTPUT_FILE"] = output_path

      stdout, stderr = capture_io { invoke(ROTATE_TASK) }

      assert_empty stdout
      assert_empty stderr
      replacement = disclosed_secret(output_path)
      assert_equal 1, File.read(output_path).scan(replacement).length
      refute original.client.reload.authenticates_secret?(original.client_secret)
      assert original.client.authenticates_secret?(replacement)
    end
  end

  test "a failed create removes the empty exclusive output file" do
    Hitch::Client.register!(client_id: "duplicate", client_name: "Existing",
      redirect_uris: [ "https://client.test/existing" ])

    Dir.mktmpdir("hitch-credentials") do |directory|
      output_path = File.join(directory, "unused.credentials")
      configure_create(output_path, client_id: "duplicate")

      assert_raises(ActiveRecord::RecordInvalid) { capture_io { invoke(CREATE_TASK) } }

      refute_path_exists output_path
    end
  end

  test "a disclosure write failure rolls back confidential client creation" do
    task_writer = Hitch.const_get(:ClientCredentialTask, false)
    fake_tty = StringIO.new
    def fake_tty.tty? = true
    open_writer = lambda do |*, &block|
      block.call(FailingWriter.new)
    end

    stub_class_method(File, :open, open_writer) do
      assert_raises(Errno::ENOSPC) do
        task_writer.disclose(stdin: fake_tty, tty_path: "/unused") do
          credentials = Hitch::Client.register_confidential!(
            client_id: "write-failed",
            client_name: "Write Failed",
            redirect_uris: [ "https://client.test/callback" ]
          )
          "client_id=#{credentials.client.client_id}\nclient_secret=#{credentials.client_secret}\n"
        end
      end
    end

    refute Hitch::Client.exists?(client_id: "write-failed")
  end

  test "a disclosure flush failure rolls back rotation and preserves the old credential" do
    original = Hitch::Client.register_confidential!(
      client_id: "flush-failed",
      client_name: "Flush Failed",
      redirect_uris: [ "https://client.test/callback" ]
    )
    client = original.client
    before = client.attributes.slice(
      "client_secret_digest", "client_secret_issued_at", "client_secret_rotated_at", "updated_at"
    )
    writer = FailingWriter.new
    writer.define_singleton_method(:write) { |*| 1 }
    writer.define_singleton_method(:flush) { raise Errno::ENOSPC }
    fake_tty = StringIO.new
    def fake_tty.tty? = true
    open_writer = lambda do |*, &block|
      block.call(writer)
    end
    task_writer = Hitch.const_get(:ClientCredentialTask, false)

    stub_class_method(File, :open, open_writer) do
      assert_raises(Errno::ENOSPC) do
        task_writer.disclose(stdin: fake_tty, tty_path: "/unused") do
          rotated = client.rotate_secret!
          "client_id=#{rotated.client.client_id}\nclient_secret=#{rotated.client_secret}\n"
        end
      end
    end

    client.reload
    assert_equal before, client.attributes.slice(*before.keys)
    assert client.authenticates_secret?(original.client_secret)
  end

  private

  def configure_create(output_path, client_id:)
    ENV["OUTPUT_FILE"] = output_path
    ENV["CLIENT_ID"] = client_id
    ENV["NAME"] = "Deployment Bot"
    ENV["REDIRECT_URI"] = "https://client.test/callback"
  end

  def invoke(name)
    Rake::Task[name].invoke
  ensure
    Rake::Task[name].reenable
  end

  def disclosed_secret(path)
    lines = File.readlines(path, chomp: true)
    values = lines.filter_map { |line| line.delete_prefix("client_secret=") if line.start_with?("client_secret=") }
    assert_equal 1, values.length
    values.first
  end
end
