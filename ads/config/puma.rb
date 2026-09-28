port ENV.fetch('PORT', 3000)
log_requests true

# Every POST /ads holds a thread for the duration of a blocking AMQP RPC to auth,
# and geocoder's PUT callbacks land in this same pool. At Puma's default of 5 the
# two starve each other under load.
threads Integer(ENV.fetch('PUMA_MIN_THREADS', 5)), Integer(ENV.fetch('PUMA_MAX_THREADS', 16))