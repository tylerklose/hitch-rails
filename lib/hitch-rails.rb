# frozen_string_literal: true

# Shim so Bundler.require finds the gem under its dasherized name.
# All real code lives in lib/hitch.rb (underscore matches the
# module namespace Hitch).
require "hitch"
