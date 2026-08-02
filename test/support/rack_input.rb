# frozen_string_literal: true

require "stringio"

module RackInputTestSupport
  AppResponse = Data.define(:status, :headers, :body)

  class NonRewindableInput
    attr_reader :bytes_read, :read_calls

    def initialize(bytes, max_chunk_size: nil)
      @stream = StringIO.new(bytes)
      @max_chunk_size = max_chunk_size
      @bytes_read = 0
      @read_calls = []
    end

    def read(*arguments)
      @read_calls << arguments
      effective_arguments = arguments.dup
      if @max_chunk_size && effective_arguments.first
        effective_arguments[0] = [ effective_arguments.first, @max_chunk_size ].min
      end

      result = @stream.read(*effective_arguments)
      @bytes_read += result.bytesize if result
      result
    end

    def gets(...)
      @stream.gets(...)
    end

    def each(...)
      @stream.each(...)
    end

    def close
      @stream.close
    end
  end

  def call_app_with_input(path:, input:, content_type:, host: "www.example.com", headers: {})
    environment = Rack::MockRequest.env_for(
      "https://#{host}#{path}",
      method: "POST",
      input: ""
    )
    environment["rack.input"] = input
    environment["CONTENT_LENGTH"] = input_size(input).to_s
    environment["CONTENT_TYPE"] = content_type
    environment["REMOTE_ADDR"] = "127.0.0.1"
    headers.each { |name, value| environment[name] = value }

    status, response_headers, response = Rails.application.call(environment)
    body = +""
    response.each { |part| body << part }
    response.close if response.respond_to?(:close)
    AppResponse.new(status:, headers: response_headers, body:)
  end

  private

  def input_size(input)
    input.instance_variable_get(:@stream).size
  end
end
