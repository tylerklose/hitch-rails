# frozen_string_literal: true

require "test_helper"

# Direct policy-matrix coverage for the one shared JSON copier. Every
# boundary suite (context, result, tool, registry) exercises its own policy
# through the production call sites; this suite pins the engine itself so a
# mutation in any policy branch dies here even when no boundary uses it.
class Hitch::MCP::JsonValuesTest < ActiveSupport::TestCase
  JSON_VALUES = Hitch::MCP::Internal::JsonValues
  INVALID = Object.new

  test "default policy is a plain unvalidated unfrozen copy" do
    string_key = "key"
    integer_key = 42
    foreign = Object.new
    symbol_value = :kept
    inner = { string_key => +"text", integer_key => foreign, "symbol" => symbol_value, "nan" => Float::NAN }
    source = { "outer" => inner, "list" => [ +"entry" ] }

    copy = JSON_VALUES.copy(source)

    refute_same source, copy
    refute_predicate copy, :frozen?
    refute_predicate copy.fetch("outer"), :frozen?
    assert_same string_key, copy.fetch("outer").keys.first
    assert_same foreign, copy.fetch("outer").fetch(integer_key)
    assert_same symbol_value, copy.fetch("outer").fetch("symbol")
    assert_predicate copy.fetch("outer").fetch("nan"), :nan?
    text = copy.fetch("outer").fetch(string_key)
    assert_equal "text", text
    refute_same inner.fetch(string_key), text
    refute_predicate text, :frozen?
    refute_same source.fetch("list").first, copy.fetch("list").first
  end

  test "default policy keeps the last of duplicate identity-hash keys" do
    first = +"same"
    second = +"same"
    source = {}.compare_by_identity
    source[first] = 1
    source[second] = 2

    assert_equal({ "same" => 2 }, JSON_VALUES.copy(source))
  end

  test "string key policy copies subclassed keys and rejects the rest" do
    subclass = Class.new(String)
    key = subclass.new("subclassed")
    copy = JSON_VALUES.copy({ key => 1 }, keys: :string, freeze: true)

    copied_key = copy.keys.first
    assert_equal "subclassed", copied_key
    refute_same key, copied_key
    assert_instance_of subclass, copied_key
    assert_predicate copied_key, :frozen?

    handler, calls = capture_invalid
    assert_same INVALID, JSON_VALUES.copy({ 7 => 1 }, keys: :string, on_invalid: handler)
    assert_equal [ [ :key, 7 ] ], calls
  end

  test "stringify_symbols key policy converts symbols and rejects other key types" do
    subclass = Class.new(String)
    source_key = subclass.new("plain")
    copy = JSON_VALUES.copy(
      { sym: 1, source_key => 2 },
      keys: :stringify_symbols, freeze: true
    )
    assert_equal({ "sym" => 1, "plain" => 2 }, copy)
    assert copy.keys.all?(&:frozen?)
    refute_same source_key, copy.keys.last
    refute_predicate source_key, :frozen?

    handler, calls = capture_invalid
    assert_same INVALID, JSON_VALUES.copy({ 1.5 => 1 }, keys: :stringify_symbols, on_invalid: handler)
    assert_equal [ [ :key, 1.5 ] ], calls
  end

  test "preserve key policy copies strings, keeps symbols, rejects the rest" do
    string_key = Class.new(String).new("declared")
    copy = JSON_VALUES.copy({ string_key => 1, sym: 2 }, keys: :preserve, freeze: true)

    copied_string_key, copied_symbol_key = copy.keys
    assert_equal "declared", copied_string_key
    refute_same string_key, copied_string_key
    assert_predicate copied_string_key, :frozen?
    refute_predicate string_key, :frozen?
    assert_same :sym, copied_symbol_key

    handler, calls = capture_invalid
    assert_same INVALID, JSON_VALUES.copy({ 9 => 1 }, keys: :preserve, on_invalid: handler)
    assert_equal [ [ :key, 9 ] ], calls
  end

  test "to_s key policy stringifies and freezes every key" do
    subclass = Class.new(String)
    subclass_key = subclass.new("subclassed")
    copy = JSON_VALUES.copy({ 42 => 1, sym: 2, subclass_key => 3 }, keys: :to_s)
    assert_equal({ "42" => 1, "sym" => 2, "subclassed" => 3 }, copy)
    assert copy.keys.all?(&:frozen?)
  end

  test "duplicate policy rejects collisions after key normalization with the collided key" do
    handler, calls = capture_invalid
    result = JSON_VALUES.copy(
      { "same" => 1, same: 2 },
      keys: :stringify_symbols, duplicates: :reject, on_invalid: handler
    )

    assert_same INVALID, result
    assert_equal [ [ :duplicate_key, "same" ] ], calls
  end

  test "symbol values follow the symbols policy" do
    assert_equal({ "v" => "sym" }, JSON_VALUES.copy({ "v" => :sym }, symbols: :to_s))

    handler, calls = capture_invalid
    assert_same INVALID, JSON_VALUES.copy({ "v" => :sym }, symbols: :reject, on_invalid: handler)
    assert_equal [ [ :foreign, nil ] ], calls
  end

  test "foreign values follow the foreign policy and freeze with the copy" do
    foreign = Object.new
    copy = JSON_VALUES.copy({ "v" => foreign }, keys: :to_s, freeze: true)
    assert_same foreign, copy.fetch("v")
    assert_predicate copy.fetch("v"), :frozen?

    handler, calls = capture_invalid
    assert_same INVALID, JSON_VALUES.copy({ "v" => foreign }, foreign: :reject, on_invalid: handler)
    assert_equal [ [ :foreign, nil ] ], calls
  end

  test "finite policy rejects only non-finite floats" do
    handler, calls = capture_invalid
    [ Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |value|
      calls.clear
      assert_same INVALID, JSON_VALUES.copy({ "v" => value }, finite: true, on_invalid: handler)
      assert_equal [ [ :non_finite, nil ] ], calls
    end

    copy = JSON_VALUES.copy({ "v" => 1.5, "i" => 7, "t" => true, "f" => false, "n" => nil }, finite: true)
    assert_equal({ "v" => 1.5, "i" => 7, "t" => true, "f" => false, "n" => nil }, copy)
  end

  test "cyclic structures are rejected as recursive" do
    handler, calls = capture_invalid
    cyclic_hash = {}
    cyclic_hash["self"] = cyclic_hash
    assert_same INVALID, JSON_VALUES.copy(cyclic_hash, on_invalid: handler)
    assert_equal [ [ :recursive, nil ] ], calls

    calls.clear
    cyclic_array = []
    cyclic_array << cyclic_array
    assert_same INVALID, JSON_VALUES.copy({ "list" => cyclic_array }, on_invalid: handler)
    assert_equal [ [ :recursive, nil ] ], calls
  end

  test "shared substructure is not recursive" do
    shared_hash = { "k" => 1 }
    shared_array = [ 1 ]
    source = {
      "first" => shared_hash,
      "second" => shared_hash,
      "lists" => [ shared_array, shared_array ],
      "nested" => { "again" => shared_hash }
    }

    copy = JSON_VALUES.copy(source, freeze: true)

    assert_equal source, copy
    refute_same copy.fetch("first"), copy.fetch("second")
  end

  test "max_depth is an exact ceiling counted from the root" do
    handler, calls = capture_invalid

    assert_equal({ "a" => 1 }, JSON_VALUES.copy({ "a" => 1 }, max_depth: 2, on_invalid: handler))
    assert_empty calls

    assert_same INVALID, JSON_VALUES.copy({ "a" => { "b" => 1 } }, max_depth: 2, on_invalid: handler)
    assert_equal [ [ :depth, nil ] ], calls

    calls.clear
    assert_same INVALID, JSON_VALUES.copy({ "a" => [ 1 ] }, max_depth: 2, on_invalid: handler)
    assert_equal [ [ :depth, nil ] ], calls

    calls.clear
    assert_equal [ [] ], JSON_VALUES.copy([ [] ], max_depth: 2, on_invalid: handler)
    assert_empty calls
    assert_same INVALID, JSON_VALUES.copy([ [ 1 ] ], max_depth: 2, on_invalid: handler)
    assert_equal [ [ :depth, nil ] ], calls
  end

  test "max_objects is an exact ceiling counting hashes only" do
    handler, calls = capture_invalid
    two_hashes = { "a" => { "b" => 1 }, "list" => [ 1, [ 2 ] ] }

    assert_equal two_hashes, JSON_VALUES.copy(two_hashes, max_objects: 2, on_invalid: handler)
    assert_empty calls

    three_hashes = { "a" => { "b" => 1 }, "c" => { "d" => 2 } }
    assert_same INVALID, JSON_VALUES.copy(three_hashes, max_objects: 2, on_invalid: handler)
    assert_equal [ [ :objects, nil ] ], calls
  end

  test "freeze policy deep-freezes every level" do
    copy = JSON_VALUES.copy({ "outer" => { "inner" => [ +"text" ] } }, keys: :string, freeze: true)

    assert_predicate copy, :frozen?
    assert_predicate copy.fetch("outer"), :frozen?
    assert_predicate copy.fetch("outer").fetch("inner"), :frozen?
    assert_predicate copy.fetch("outer").fetch("inner").first, :frozen?
    assert copy.keys.all?(&:frozen?)
  end

  test "a raising handler propagates and the default handler names the reason" do
    error = assert_raises(RuntimeError) do
      JSON_VALUES.copy({ 7 => 1 }, keys: :string, on_invalid: ->(_reason, _detail) { raise "handler-raised" })
    end
    assert_equal "handler-raised", error.message

    error = assert_raises(ArgumentError) { JSON_VALUES.copy({ 7 => 1 }, keys: :string) }
    assert_equal "JSON value copy rejected (key)", error.message
  end

  test "a replacement handler replaces the entire copy from any depth" do
    handler, calls = capture_invalid
    source = { "deep" => [ { "deeper" => { 7 => 1 } } ] }

    assert_same INVALID, JSON_VALUES.copy(source, keys: :string, on_invalid: handler)
    assert_equal [ [ :key, 7 ] ], calls
  end

  test "deep_string_copy_and_freeze stringifies keys and freezes everything" do
    symbol_value = :kept
    copy = JSON_VALUES.deep_string_copy_and_freeze({ sym: [ +"text" ], 42 => symbol_value })

    assert_equal({ "sym" => [ "text" ], "42" => symbol_value }, copy)
    assert_predicate copy, :frozen?
    assert_predicate copy.fetch("sym"), :frozen?
    assert_predicate copy.fetch("sym").first, :frozen?
    assert_same symbol_value, copy.fetch("42")
    assert copy.keys.all?(&:frozen?)
  end

  test "unknown policies are loud" do
    error = assert_raises(ArgumentError) { JSON_VALUES.copy({ "k" => 1 }, keys: :bogus) }
    assert_equal "unknown keys policy :bogus", error.message

    error = assert_raises(ArgumentError) { JSON_VALUES.copy({ "k" => :sym }, symbols: :bogus) }
    assert_equal "unknown symbols policy :bogus", error.message
  end

  private

  def capture_invalid
    calls = []
    handler = lambda do |reason, detail|
      calls << [ reason, detail ]
      INVALID
    end
    [ handler, calls ]
  end
end
