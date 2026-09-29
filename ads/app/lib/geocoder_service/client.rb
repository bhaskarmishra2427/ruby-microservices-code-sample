# frozen_string_literal: true

require 'dry/initializer'
require_relative '../base_faraday_service'
require_relative 'api'
require_relative '../rabbit_mq'

module GeocoderService
  class Client
    extend Dry::Initializer[undefined: false]
    include BaseFaradayService
    include Api

    option :url, default: proc { 'http://localhost:6000/api/v1' }
    option :connection, default: proc { build_connection }
    option :queue, default: -> { create_queue }

    private

    def create_queue
      channel = RabbitMQ.channel
      channel.queue('geocoding', durable: true)
    end

    def publish(payload, opts = {})
      queue.publish(
        payload,
        opts.merge(
          persistent: true,
          headers: AmqpTraceContext.inject(
            app_id: ENV['APP_NAME'],
            request_id: Thread.current[:request_id]
          )
        )
      )
    end
  end
end
