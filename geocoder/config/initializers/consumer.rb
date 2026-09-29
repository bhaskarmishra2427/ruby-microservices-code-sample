# frozen_string_literal: true

require 'benchmark'

channel = RabbitMQ.consumer_channel
queue = channel.queue('geocoding', durable: true)

queue.subscribe(manual_ack: true) do |delivery_info, properties, payload|
  # Runs the handler in its own New Relic transaction and links it to the caller's
  # trace via the headers ads injected. This is also what connects the outgoing
  # HTTP callback below to the trace that originally created the ad.
  AmqpTraceContext.in_message_transaction('geocoding', properties.headers) do
    payload = JSON(payload)
    Thread.current[:request_id] = properties.headers['request_id']
    coordinates = nil
    benchmark = Benchmark.measure { coordinates = Geocoder::FindService.geocode(payload['city']) }

    Metrics.geocoding_process_time.observe(benchmark.real, labels: { result: 'geocoding' })

    Application.logger.info(
      'geocoded coordinates',
      city: payload['city'],
      coordinates: coordinates
    )

    AdsService::Client.new.update_coords(payload['id'], coordinates)

    channel.ack(delivery_info.delivery_tag)
  end
end
