source "https://rubygems.org"

# Specify your gem's dependencies in hitch-rails.gemspec.
gemspec

gem "puma"

gem "pg"

group :test do
  gem "mutant", "0.16.3", require: false
  gem "mutant-minitest", "0.16.3", require: false
  # Exercises RedisCacheStore as one supported admission backend. Hitch itself
  # declares no runtime Redis dependency; see docs/operator/rate_limiting.md.
  gem "redis", ">= 5", "< 7"
end

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
