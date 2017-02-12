# frozen_string_literal: true

module Speculation
  # @private
  class Identifier
    attr_reader :namespace, :name

    def initialize(namespace, name, instance_method)
      @namespace = namespace
      @name = name
      @instance_method = instance_method
    end

    def instance_method?
      @instance_method
    end

    def get_method
      @instance_method ? @namespace.instance_method(@name) : @namespace.method(@name)
    end

    def redefine_method!(new_method)
      if @instance_method
        name = @name
        @namespace.class_eval { define_method(name, new_method) }
      else
        @namespace.define_singleton_method(@name, new_method)
      end
    end

    def hash
      [@namespace, @name, @instance_method].hash
    end

    def ==(other)
      self.class === other &&
        other.hash == hash
    end
    alias eql? ==

    def to_s
      sep = @instance_method ? "#" : "."
      "#{@namespace}#{sep}#{@name}"
    end
    alias inspect to_s
  end
end
