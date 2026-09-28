# frozen_string_literal: true

module BasicService
  module ClassMethods
    # Keywords must be forwarded explicitly. Under Ruby 3 a bare *args collects
    # them into a positional Hash, which dry-initializer then ignores entirely,
    # leaving every option unset instead of raising.
    def call(*args, **kwargs, &block)
      new(*args, **kwargs, &block).call
    end
  end

  def self.prepended(base)
    base.extend Dry::Initializer[undefined: false]
    base.extend ClassMethods
  end

  attr_reader :errors

  def initialize(*args, **kwargs)
    super(*args, **kwargs)
    @errors = []
  end

  def call
    super
    self
  end

  def success?
    !failure?
  end

  def failure?
    @errors.any?
  end

  private

  def fail!(messages)
    @errors += Array(messages)
    self
  end
end
