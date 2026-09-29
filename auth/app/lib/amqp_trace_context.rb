# frozen_string_literal: true

# Carries New Relic distributed trace context across the AMQP hops.
#
# The agent auto-instruments Bunny with MessageBroker Put/Take segments, but it
# does NOT propagate trace context over AMQP (the same is true for Kafka and
# Cassandra). Without this, every hop is recorded as its own disconnected trace
# and the service map shows ads, auth and geocoder as three unconnected entities.
#
# The AMQP headers hash already carries request_id and correlation_id, so it is a
# proven carrier for our own metadata; trace context simply rides along in it.
#
# This file is duplicated verbatim in all three services, which are deployed
# independently and share no code. Keep the copies in sync.
module AmqpTraceContext
  extend self

  # Producer side. Returns the headers hash with 'traceparent', 'tracestate' and
  # 'newrelic' added. Takes and returns a plain Hash so callers can pass their
  # existing headers inline. Never raises: losing a trace link must not fail a
  # publish.
  def inject(headers = {})
    return headers unless available?

    ::NewRelic::Agent::DistributedTracing.insert_distributed_trace_headers(headers)
    headers
  rescue StandardError => e
    warn_once('failed to inject AMQP trace context', e)
    headers
  end

  # Consumer side. Runs the block inside its own New Relic transaction and links
  # it to the producer's trace.
  #
  # An explicit transaction is required: the subscribe block runs on a Bunny work
  # pool thread with no transaction in scope, so without this the agent only
  # creates one incidentally when the block happens to publish or make an HTTP
  # call — which is why consumed messages previously showed up as
  # OtherTransaction/Message/RabbitMQ/Exchange/Named/Default rather than as work
  # attributable to a queue.
  def in_message_transaction(queue_name, headers)
    return yield unless available?

    ::NewRelic::Agent::Tracer.in_transaction(
      partial_name: "RabbitMQ/Queue/Named/#{queue_name}",
      category: :message
    ) do
      accept(headers)
      yield
    end
  end

  private

  # 'AMQP' is one of New Relic's accepted transport types.
  def accept(headers)
    return if headers.nil?

    ::NewRelic::Agent::DistributedTracing.accept_distributed_trace_headers(headers, 'AMQP')
  rescue StandardError => e
    warn_once('failed to accept AMQP trace context', e)
  end

  # Guarded so the app still runs with the agent absent or disabled. Checks for the
  # methods rather than just the module, so an API rename degrades to "no trace
  # link" instead of raising on every publish.
  def available?
    defined?(::NewRelic::Agent::DistributedTracing) &&
      defined?(::NewRelic::Agent::Tracer) &&
      ::NewRelic::Agent::DistributedTracing.respond_to?(:insert_distributed_trace_headers) &&
      ::NewRelic::Agent::DistributedTracing.respond_to?(:accept_distributed_trace_headers) &&
      ::NewRelic::Agent::Tracer.respond_to?(:in_transaction)
  end

  def warn_once(message, error)
    log = logger
    return if log.nil?

    log.warn(message, error: error.message)
  end

  # ads names its base controller ApplicationController; auth and geocoder use
  # Application.
  def logger
    return ::ApplicationController.logger if defined?(::ApplicationController)
    return ::Application.logger if defined?(::Application)

    nil
  end
end
