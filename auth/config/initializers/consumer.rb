# frozen_string_literal: true

channel = RabbitMQ.consumer_channel
exchange = channel.default_exchange
queue = channel.queue('auth', durable: true)

queue.subscribe(manual_ack: true) do |delivery_info, properties, payload|
  payload = JSON.parse(payload)
  extracted_token = begin
                      JwtEncoder.decode(payload['token'])
                    rescue JWT::DecodeError
                      {}
                    end
  result = Auth::FetchUserService.call(extracted_token['uuid'])
  user_id = result.success? ? result.user.id : nil

  Application.logger.info(
    'authenticate user',
    uuid: extracted_token['uuid'],
    user_id: user_id
  )

  exchange.publish(
    { user_id: user_id }.to_json,
    routing_key: properties.reply_to,
    headers: {
      app_id: Settings.app.name,
      # This block runs on a Bunny work pool thread, where the thread local is never set.
      request_id: properties.headers['request_id'],
      correlation_id: properties.headers['correlation_id']
    }
  )

  # Subscribed with manual_ack, so without this every handled message stays
  # unacknowledged forever and the queue grows one entry per request.
  channel.ack(delivery_info.delivery_tag)
end
