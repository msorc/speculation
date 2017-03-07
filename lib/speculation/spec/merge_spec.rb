# frozen_string_literal: true
module Speculation
  # @private
  class MergeSpec < Spec
    include NamespacedSymbols
    S = Speculation

    def initialize(preds)
      @preds = preds
    end

    def conform(x)
      ms = @preds.map { |pred| S.dt(pred, x) }

      if ms.any?(&S.method(:invalid?))
        ns(S, :invalid)
      else
        ms.reduce(&:merge)
      end
    end

    def explain(path, via, inn, x)
      @preds.
        flat_map { |pred| S.explain1(pred, path, via, inn, x) }.
        compact
    end

    def gen(overrides, path, rmap)
      return @gen if @gen

      gens = @preds.
        map { |pred| S.gensub(pred, overrides, path, rmap) }

      ->(r) do
        gens.map { |gen| gen.call(r) }.reduce(&:merge)
      end
    end
  end
end