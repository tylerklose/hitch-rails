require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"

# Repo-development verification of the checked-in Lattice artifacts. Opt-in:
# nothing in bin/ci or `rails test` needs the lattice executable — run this
# after editing a schema under test/lattice/.
namespace :lattice do
  desc "Regenerate every checked Lattice artifact and diff it against the repo"
  task :verify do
    require "json"
    require "open3"

    root = __dir__
    checked = [
      { schema: "test/lattice/doctor.json",
        scenarios: "test/lattice/doctor_scenarios.json", args: [] },
      { schema: "test/lattice/tool_generator.json",
        scenarios: "test/lattice/tool_generator_scenarios.json", args: [] },
      { schema: "test/lattice/mcp_tool_authorization.json",
        scenarios: "test/lattice/mcp_tool_authorization_scenarios.json",
        args: [ "--strength", "8" ] }
    ]

    generate = lambda do |schema, args|
      output, error, status = Bundler.with_unbundled_env do
        Open3.capture3(
          "lattice", "generate", File.join(root, schema),
          "--format", "json", "--seed", "42", *args, chdir: root
        )
      end
      abort "lattice failed for #{schema}:\n#{error}" unless status.success?
      JSON.parse(output)
    end

    # Only the rows are the artifact — the document header records whichever
    # lattice build produced it.
    checked.each do |artifact|
      generated = generate.call(artifact[:schema], artifact[:args])
      recorded = JSON.parse(File.read(File.join(root, artifact[:scenarios])))
      unless generated.fetch("scenarios") == recorded.fetch("scenarios")
        abort "#{artifact[:scenarios]} differs from regeneration — " \
          "regenerate it or revert the schema edit"
      end
      puts "#{artifact[:scenarios]}: #{recorded.fetch('scenarios').length} rows verified"
    end

    # The result-normalization lattice has no checked scenarios file; its
    # fourteen terminal paths are the recorded expectation.
    rows = generate.call("test/lattice/mcp_result_normalization.json", [ "--strength", "3" ])
      .fetch("scenarios")
      .map { |row| row.fetch("values").values_at("result_path", "wire_size", "public_outcome") }
    expected = [
      %w[text within success],
      %w[text exact success],
      %w[text over generic_error],
      %w[structured_schema_accepts within success],
      %w[structured_schema_accepts exact success],
      %w[structured_schema_accepts over generic_error],
      %w[explicit_error within explicit_safe_error],
      %w[explicit_error exact explicit_safe_error],
      %w[explicit_error over generic_error],
      %w[structured_schema_missing not_applicable generic_error],
      %w[structured_schema_rejects not_applicable generic_error],
      %w[invalid_return not_applicable generic_error],
      %w[serialization_failure not_applicable generic_error],
      %w[host_raises not_applicable generic_error]
    ]
    abort "mcp_result_normalization.json no longer derives its fourteen terminal paths" unless rows == expected
    puts "test/lattice/mcp_result_normalization.json: 14 terminal paths verified"
  end
end
