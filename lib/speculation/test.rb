# frozen_string_literal: true

# This is a Ruby translation of clojure.spec.test:
#   https://github.com/clojure/clojure/blob/master/src/clj/clojure/spec/test.clj
# All credit belongs with Rich Hickey and contributors for their original work.

require "concurrent"
require "pp"
require "speculation/pmap"
require "speculation/gen"

module Speculation
  module Test
    extend NamespacedSymbols
    extend Pmap

    # @private
    S = Speculation

    @instrumented_methods = Concurrent::Atom.new({})
    @instrument_enabled = Concurrent::ThreadLocalVar.new(true)

    class << self
      # if false, instrumented methods call straight through
      attr_accessor :instrument_enabled
    end

    # Disables instrument's checking of calls within a block
    def self.with_instrument_disabled
      instrument_enabled.value = false
      yield
    ensure
      instrument_enabled.value = true
    end

    # Given an opts hash as per instrument, returns the set of methods that can
    # be instrumented.
    # @param opts [Hash]
    # @return [Array<Method>]
    def self.instrumentable_methods(opts = {})
      if opts[:gen]
        unless opts[:gen].keys.all? { |k| k.is_a?(Method) || k.is_a?(Symbol) }
          raise ArgumentError, "instrument :gen expects Method or Symbol keys"
        end
      end

      S.registry.keys.select(&method(:fn_spec_name?)).to_set.tap { |set|
        set.merge(opts[:spec].keys)    if opts[:spec]
        set.merge(opts[:stub])         if opts[:stub]
        set.merge(opts[:replace].keys) if opts[:replace]
      }.map(&method(:Method))
    end

    # @param method_or_methods [Method, Array<Method>]
    #   Instruments the methods named by method-or-methods, a method or collection
    #   of methods, or all instrumentable methods if method_or_methods is not
    #   specified.
    #   If a method has an :args fn-spec, replaces the method with a method that
    #   checks arg conformance (throwing an exception on failure) before
    #   delegating to the original method.
    # @param opts [Hash] opts hash can be used to override registered specs, and/or to replace
    #   method implementations entirely. Opts for methods not included in
    #   method-or-methods are ignored. This facilitates sharing a common options
    #   hash across many different calls to instrument
    # @option opts :spec [Hash] a map from methods to override specs.
    #   :spec overrides registered method specs with specs you provide. Use :spec
    #   overrides to provide specs for libraries that do not have them, or to
    #   constrain your own use of a fn to a subset of its spec'ed contract.
    #   :spec can be used in combination with :stub or :replace.
    #
    # @option opts :stub [Set, Array] a set of methods to be replaced by stubs.
    #   :stub replaces a fn with a stub that checks :args, then uses the :ret spec
    #   to generate a return value.
    #
    # @option opts :gen [Hash{Symbol => Proc}] a map from spec names to generator overrides.
    #   :gen overrides are used only for :stub generation.
    #
    # @option opts :replace [Hash{Method => Proc}] a map from methods to replacement procs.
    #   :replace replaces a method with a method that checks args conformance,
    #   then invokes the method/proc you provide, enabling arbitrary stubbing and
    #   mocking.
    #
    # @return [Array<Method>] a collection of methods instrumented.
    def self.instrument(method_or_methods = instrumentable_methods, opts = {})
      if opts[:gen]
        gens = opts[:gen].reduce({}) { |h, (k, v)| h.merge(S.MethodIdentifier(k) => v) }
        opts = opts.merge(:gen => gens)
      end

      Array(method_or_methods).
        map { |method| S.MethodIdentifier(method) }.
        uniq.
        map { |ident| instrument1(ident, opts) }.
        compact.
        map(&method(:Method))
    end

    # Undoes instrument on the method_or_methods, specified as in instrument.
    # With no args, unstruments all instrumented methods.
    # @param method_or_methods [Method, Array<Method>]
    # @return [Array<Method>] a collection of methods unstrumented
    def self.unstrument(method_or_methods = nil)
      method_or_methods ||= @instrumented_methods.value.keys

      Array(method_or_methods).
        map { |method| S.MethodIdentifier(method) }.
        map { |ident| unstrument1(ident) }.
        compact.
        map(&method(:Method))
    end

    # Runs generative tests for method using spec and opts.
    # @param method [Method]
    # @param spec [Spec]
    # @param opts [Hash]
    # @return [Hash]
    # @see check see check for options and return
    def self.check_method(method, spec, opts = {})
      validate_check_opts(opts)
      check1(S.MethodIdentifier(method), spec, opts)
    end

    # @param opts [Hash] an opts hash as per `check`
    # @return [Array<Method>] the array of methods that can be checked.
    def self.checkable_methods(opts = {})
      validate_check_opts(opts)

      S.
        registry.
        keys.
        select { |k| fn_spec_name?(k) && !k.instance_method? }.
        concat(Hash(opts[:spec]).keys).
        map(&method(:Method))
    end

    # Run generative tests for spec conformance on method_or_methods. If
    # method_or_methods is not specified, check all checkable methods.
    #
    # @param method_or_methods [Array<Method>, Method]
    # @param opts [Hash]
    # @option opts :num_tests [Integer] (1000) number of times to generatively test each method
    # @option opts :gen [Hash] map from spec names to generator overrides.
    #   Generator overrides are passed to Speculation.gen when generating method args.
    # @return [Array<Hash>] an array of check result hashes with the following keys:
    #   * :spec       the spec tested
    #   * :method     optional method tested
    #   * :failure    optional test failure
    #   * :result     optional boolean as to whether all generative tests passed
    #   * :num_tests  optional number of generative tests ran
    #
    #   :failure is a hash that will contain a :failure key with possible values:
    #
    #   * :check_failed   at least one checked return did not conform
    #   * :no_args_spec   no :args spec provided
    #   * :no_fspec       no fspec provided
    #   * :no_gen         unable to generate :args
    #   * :instrument     invalid args detected by instrument
    def self.check(method_or_methods = nil, opts = {})
      method_or_methods ||= checkable_methods

      checkable = Set(checkable_methods(opts))
      checkable.map!(&S.method(:MethodIdentifier))

      methods = Set(method_or_methods)
      methods.map!(&S.method(:MethodIdentifier))

      pmap(methods.intersection(checkable)) { |ident|
        check1(ident, S.get_spec(ident), opts)
      }
    end

    # Given a check result, returns an abbreviated version suitable for summary use.
    # @param x [Hash]
    # @return [Hash]
    def self.abbrev_result(x)
      if x[:failure]
        x.reject { |k, _| k == :ret }.
          merge(:spec    => x[:spec].inspect,
                :failure => unwrap_failure(x[:failure]))
      else
        x.reject { |k, _| [:spec, :ret].include?(k) }
      end
    end

    # Given a collection of check_results, e.g. from `check`, pretty prints the
    # summary_result (default abbrev_result) of each.
    #
    # @param check_results [Array] a collection of check_results
    # @yield [Hash]
    # @return [Hash] a hash with :total, the total number of results, plus a key with a
    #   count for each different :type of result.
    # @see check see check for check_results
    # @see abbrev_result
    def self.summarize_results(check_results, &summary_result)
      summary_result ||= method(:abbrev_result)

      check_results.reduce(:total => 0) { |summary, result|
        pp summary_result.call(result)

        result_key = result_type(result)

        summary.merge(
          :total     => summary[:total].next,
          result_key => summary.fetch(result_key, 0).next
        )
      }
    end

    # @param modules [Module, Class]
    # @return [Array<Method>] an array of public and protected singleton
    #   methods belonging to modules
    def self.enumerate_methods(*modules)
      modules.flat_map { |mod| mod.methods(false).map(&mod.method(:method)) } # method
    end

    # @private
    def self.radagen_quick_check(gen, num_tests)
      i = 0

      gen.to_enum.take(num_tests).each do |genned|
        i += 1
        args, blk = genned
        result = yield([args, blk]) rescue $!

        unless result == true
          return { :fail      => { :args => args, :block => blk },
                   :num_tests => i,
                   :result    => result }
        end
      end

      { :num_tests => i,
        :result    => true }
    end

    # @param value [Object] arguments or block value
    # @param path [Symbol] :args or :block
    # @param ident [Speculation::MethodIdentifier] the method being conformed
    # @param spec [Speculation::FSpec]
    def self.conform_method(value, path, ident, spec)
      conformed = S.conform(spec, value)

      if conformed == :"Speculation/invalid"
        backtrace = backtrace_relevant_to_instrument(caller)

        ed = S.
          _explain_data(spec, [path], [], [], value).
          merge(path => value, :failure => :instrument, :fn => ident, :caller => backtrace.first)

        raise S::Error.new("Call to '#{ident}' did not conform to spec.", ed)
      end
    end

    class << self
      private

      def spec_checking_fn(ident, method, fspec)
        fspec = S.send(:maybe_spec, fspec)

        ->(*args, &block) do
          method = method.bind(self) if method.is_a?(UnboundMethod)

          if Test.instrument_enabled.value
            Test.with_instrument_disabled do
              Test.conform_method(args, :args, ident, fspec.args)
              Test.conform_method(block, :block, ident, fspec.block) if fspec.block

              begin
                Test.instrument_enabled.value = true
                method.call(*args, &block)
              ensure
                Test.instrument_enabled.value = false
              end
            end
          else
            method.call(*args, &block)
          end
        end
      end

      def no_fspec(ident, spec)
        S::Error.new("#{ident} not spec'ed", :method => ident, :spec => spec, :failure => :no_fspec)
      end

      def instrument1(ident, opts)
        spec = S.get_spec(ident)

        raw, wrapped = @instrumented_methods.
          value.
          fetch(ident, {}).
          values_at(:raw, :wrapped)

        current = ident.get_method
        to_wrap = wrapped == current ? raw : current

        ospec = instrument_choose_spec(spec, ident, opts[:spec])
        raise no_fspec(ident, spec) unless ospec

        ofn = instrument_choose_fn(to_wrap, ospec, ident, opts)

        checked = spec_checking_fn(ident, ofn, ospec)

        ident.redefine_method!(checked)

        wrapped = ident.get_method

        @instrumented_methods.swap do |methods|
          methods.merge(ident => { :raw => to_wrap, :wrapped => wrapped })
        end

        ident
      end

      def instrument_choose_fn(f, spec, ident, opts)
        stubs   = (opts[:stub] || []).map(&S.method(:MethodIdentifier))
        over    = opts[:gen] || {}
        replace = (opts[:replace] || {}).reduce({}) { |h, (k, v)| h.merge(S.MethodIdentifier(k) => v) }

        if stubs.include?(ident)
          Gen.generate(S.gen(spec, over))
        else
          replace.fetch(ident, f)
        end
      end

      def instrument_choose_spec(spec, ident, overrides)
        (overrides || {}).
          reduce({}) { |h, (k, v)| h.merge(S.MethodIdentifier(k) => v) }.
          fetch(ident, spec)
      end

      def unstrument1(ident)
        instrumented = @instrumented_methods.value[ident]
        return unless instrumented

        raw, wrapped = instrumented.values_at(:raw, :wrapped)

        @instrumented_methods.swap do |h|
          h.reject { |k, _v| k == ident }
        end

        current = ident.get_method

        # Only redefine to original if it has not been modified since it was
        # instrumented.
        if wrapped == current
          ident.tap { |i| i.redefine_method!(raw) }
        end
      end

      def explain_check(args, spec, v, role)
        data = unless S.valid?(spec, v)
                 S._explain_data(spec, [role], [], [], v).
                   merge(:args    => args,
                         :val     => v,
                         :failure => :check_failed)
               end

        S::Error.new("Specification-based check failed", data).tap do |e|
          e.set_backtrace(caller)
        end
      end

      # Returns true if call passes specs, otherwise returns an Error with a #data including
      # :backtrace, :cause and :data keys. :data will have a
      # :failure key.
      def check_call(method, spec, args, block)
        conformed_args = S.conform(spec.args, args) if spec.args

        if conformed_args == :"Speculation/invalid"
          return explain_check(args, spec.args, args, :args)
        end

        conformed_block = S.conform(spec.block, block) if spec.block

        if conformed_block == :"Speculation/invalid"
          return explain_check(block, spec.block, block, :block)
        end

        ret = method.call(*args, &block)

        conformed_ret = S.conform(spec.ret, ret) if spec.ret

        if conformed_ret == :"Speculation/invalid"
          return explain_check(args, spec.ret, ret, :ret)
        end

        return true unless spec.args && spec.ret && spec.fn

        if S.valid?(spec.fn, :args => conformed_args, :block => conformed_block, :ret => conformed_ret)
          true
        else
          explain_check(args, spec.fn, { :args => conformed_args, :block => conformed_block, :ret => conformed_ret }, :fn)
        end
      end

      def quick_check(method, spec, opts)
        gen = opts[:gen]
        num_tests = opts.fetch(:num_tests, 1000)

        args_gen = begin
                     S.gen(spec.args, gen)
                   rescue => e
                     return { :result => e }
                   end

        block_gen = if spec.block
                      begin
                        S.gen(spec.block, gen)
                      rescue => e
                        return { :result => e }
                      end
                    else
                      Radagen.return(nil)
                    end

        radagen_quick_check(Radagen.tuple(args_gen, block_gen), num_tests) { |(args, block)|
          check_call(method, spec, args, block)
        }
      end

      def make_check_result(method, spec, check_result)
        result = { :spec   => spec,
                   :ret    => check_result,
                   :method => method }

        if check_result[:result] && check_result[:result] != true
          result[:failure] = check_result[:result]
        end

        if check_result[:shrunk]
          result[:failure] = check_result[:shrunk][:result]
        end

        result
      end

      def check1(ident, spec, opts)
        specd = S.spec(spec)

        reinstrument = unstrument(ident).any?
        method = ident.get_method

        if specd.args
          check_result = quick_check(method, spec, opts)
          make_check_result(method, spec, check_result)
        else
          failure = { :info    => "No :args spec",
                      :failure => :no_args_spec }

          { :failure => failure,
            :method  => method,
            :spec    => spec }
        end
      ensure
        instrument(ident) if reinstrument
      end

      def validate_check_opts(opts)
        return unless opts[:gen]

        unless opts[:gen].keys.all? { |k| k.is_a?(Method) || k.is_a?(Symbol) }
          raise ArgumentErorr, "check :gen expects Method or Symbol keys"
        end
      end

      def backtrace_relevant_to_instrument(backtrace)
        backtrace.drop_while { |line| line.include?(__FILE__) }
      end

      def fn_spec_name?(spec_name)
        spec_name.is_a?(S::MethodIdentifier)
      end

      ### check reporting ###

      def failure_type(x)
        x.data[:failure] if x.is_a?(S::Error)
      end

      def unwrap_failure(x)
        failure_type(x) ? x.data : x
      end

      # Returns the type of the check result. This can be any of the
      # :failure symbols documented in 'check', or:
      #
      # :check_passed   all checked method returns conformed
      # :check_raised   checked fn threw an exception
      def result_type(ret)
        failure = ret[:failure]

        if failure.nil?
          :check_passed
        else
          failure_type(failure) || :check_raised
        end
      end

      # if x is an MethodIdentifier, return its method
      def Method(x)
        case x
        when MethodIdentifier      then x.get_method
        when Method, UnboundMethod then x
        else raise ArgumentError, "unexpected method-like object #{x}"
        end
      end

      def Set(x)
        case x
        when Set then x
        when Enumerable then Set.new(x)
        else Set[x]
        end
      end
    end
  end
end
