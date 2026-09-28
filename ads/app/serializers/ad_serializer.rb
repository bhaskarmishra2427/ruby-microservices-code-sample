# frozen_string_literal: true

require 'jsonapi/serializer'

class AdSerializer
  include JSONAPI::Serializer

  attributes :title, :description, :city, :lat, :lon
end
