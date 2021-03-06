# frozen_string_literal: true

require "test_helper"

module Speculation
  class EverySpecTest < Minitest::Test
    S = Speculation
    Gen = S::Gen
    include S::NamespacedSymbols

    def test_coll_of
      S.def(ns(:symbol_collection), S.coll_of(Symbol))

      assert_equal [:a, :b, :c], S.conform(ns(:symbol_collection), [:a, :b, :c])
      assert_equal Set[5, 10, 2], S.conform(S.coll_of(Numeric), Set[5, 10, 2])

      expected = { :a => :x, :b => :y, :c => :z }
      assert_equal expected, S.conform(S.coll_of(ns(:symbol_collection)), :a => :x, :b => :y, :c => :z)

      assert S.valid?(S.coll_of(Integer), [1, 2, 3])
      assert S.valid?(S.coll_of(Integer, :kind => ->(coll) { coll.is_a?(Array) }), [1, 2, 3])
      refute S.valid?(S.coll_of(Integer), ["a", "b", "c"])

      assert S.valid?(S.coll_of(Integer, :count => 3), [1, 2, 3])
      refute S.valid?(S.coll_of(Integer, :count => 2), [1, 2, 3])

      refute S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4), [1, 2])
      assert S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4), [1, 2, 3])
      assert S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4), [1, 2, 3, 4])
      refute S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4), [1, 2, 3, 4, 5])

      assert_kind_of Set, S.conform(S.coll_of(Integer, :into => Set[]), [1, 2, 3, 4, 5])
      assert_kind_of Hash, S.conform(S.coll_of(S.coll_of(Integer), :into => {}), [[1, 2], [3, 4]])

      Gen.generate(S.gen(ns(:symbol_collection))).each do |x|
        assert_kind_of Symbol, x
      end

      coll = Gen.generate(S.gen(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :into => Set[])))
      assert coll.count.between?(3, 4)
      assert Predicates.distinct?(coll)
      coll.each do |x|
        assert_kind_of Integer, x
      end

      assert S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :kind => Set), Set[1, 2, 3])
      refute S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :kind => Array), Set[1, 2, 3])
      assert S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :kind => Enumerable), Set[1, 2, 3])
      refute S.valid?(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :kind => Enumerable), [1, 2, 3, 3])

      assert_kind_of Array, Gen.generate(S.gen(S.coll_of(Integer, :min_count => 3, :max_count => 4, :distinct => true, :kind => Array)))
    end

    def test_tuple
      S.def(ns(:point), S.tuple(Integer, Integer, Integer))

      assert S.valid?(ns(:point), [1, 2, 3])
      refute S.valid?(ns(:point), [1, 2, "3"])

      expected = {
        :problems => [
          { :path => [2], :val => 3.0, :via => [ns(:point)], :in => [2], :pred => [Integer, [3.0]] }
        ],
        :spec     => ns(:point),
        :value    => [1, 2, 3.0]
      }

      assert_equal expected, S.explain_data(ns(:point), [1, 2, 3.0])

      assert(Gen.generate(S.gen(ns(:point))).all? { |x| x.is_a?(Integer) })
    end

    def test_hash_of
      S.def(ns(:scores), S.hash_of(String, Integer))

      expected = { "Sally" => 1000, "Joe" => 500 }
      assert_equal expected, S.conform(ns(:scores), "Sally" => 1000, "Joe" => 500)

      refute S.valid?(ns(:scores), "Sally" => true, "Joe" => 500)

      hash = Gen.generate(S.gen(ns(:scores)))

      hash.each_key do |key|
        assert_kind_of String, key
      end
      hash.each_value { |value| assert_kind_of Integer, value }
    end

    def test_explain_hash_of
      S.def(ns(:scores), S.hash_of(String, Integer))

      expected = { :problems => [{ :path => [1],
                                   :val  => "300",
                                   :via  => [ns(:scores)],
                                   :in   => ["Joe", 1],
                                   :pred => [Integer, ["300"]] }],
                   :spec     => ns(:scores),
                   :value    => { "Sally" => 1000, "Joe" => "300" } }

      assert_equal expected, S.explain_data(ns(:scores), "Sally" => 1000, "Joe" => "300")
    end

    def test_conform_unform
      spec = S.coll_of(S.or(:i => Integer, :s => String))
      assert_equal [[:i, 1], [:s, "x"]], S.conform(spec, [1, "x"])
      assert_equal [1, "x"], S.unform(spec, S.conform(spec, [1, "x"]))

      spec = S.every(S.or(:i => Integer, :s => String))
      assert_equal [1, "x"], S.conform(spec, [1, "x"])
      assert_equal [1, "x"], S.unform(spec, S.conform(spec, [1, "x"]))

      spec = S.hash_of(Integer, S.or(:i => Integer, :s => String))
      assert_equal({ 10 => [:i, 10], 20 => [:s, "x"] }, S.conform(spec, 10 => 10, 20 => "x"))
      assert_equal({ 10 => 10, 20 => "x" }, S.unform(spec, S.conform(spec, 10 => 10, 20 => "x")))

      spec = S.hash_of(S.or(:i => Integer, :s => String), Integer, :conform_keys => true)
      assert_equal({ [:i, 10] => 10, [:s, "x"] => 20 }, S.conform(spec, 10 => 10, "x" => 20))
      assert_equal({ 10 => 10, "x" => 20 }, S.unform(spec, S.conform(spec, 10 => 10, "x" => 20)))

      spec = S.every_kv(Integer, S.or(:i => Integer, :s => String))
      assert_equal({ 10 => 10, 20 => "x" }, S.conform(spec, 10 => 10, 20 => "x"))
      assert_equal({ 10 => 10, 20 => "x" }, S.unform(spec, S.conform(spec, 10 => 10, 20 => "x")))
    end

    def test_every_limits
      spec = S.every(Integer)
      value = [1, 2, 3]
      assert S.valid?(spec, value)

      value = 1.upto(S.coll_check_limit).to_a
      value[S.coll_check_limit] = "not-a-number"
      assert S.valid?(spec, value)

      value[S.coll_check_limit - 1] = "not-a-number"
      refute S.valid?(spec, value)

      value.concat(("a".."z").to_a)
      assert_equal S.coll_error_limit, S.explain_data(spec, value).fetch(:problems).count
    end

    def test_every_range
      spec = S.every(String, :kind => Range)
      value = "a".."z"
      assert S.valid?(spec, value)

      # can't generate a Range...
      assert_raises(S::Error) do
        Gen.generate(S.gen(spec))
      end
    end

    def test_every_enumerator
      spec = S.every(Integer, :kind => Enumerator, :min_count => 1)
      value = (1..10).to_enum
      assert S.valid?(spec, value)

      genned = Gen.generate(S.gen(spec))
      assert_kind_of Integer, genned.next
    end
  end
end
