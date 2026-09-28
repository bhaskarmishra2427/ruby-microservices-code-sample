module AuthService
  module Api
    def auth(token)
      response = connection.get('auth') do |request|
        request.headers['Authorization'] = "Bearer #{token}"
      end

      user_id = response.body.dig('meta', 'user_id') if response.success?

      ApplicationController.logger.info(
        'sending auth request via HTTP',
        token: token,
        success: response.success?,
        user_id: user_id
      )

      # Must be the last expression: the caller treats a falsy return as Unauthorized.
      user_id
    end
  end
end
