require 'ostruct'

module TensorStream
  # Convenience class for specifying valid data_types
  module Types
    def self.int16
      :int16
    end

    def self.float32
      :float32
    end

    def self.int32
      :int32
    end

    def self.float64
      :float64
    end

    def self.string
      :string
    end

    def self.boolean
      :boolean
    end
  end
end
