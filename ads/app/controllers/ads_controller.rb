# frozen_string_literal: true

require_relative 'application_controller'

class AdsController < ApplicationController
  namespace '/api/v1' do
    get '/ads' do
      ads = Ad.order(updated_at: :desc).page(params[:page])
      serializer = AdSerializer.new(ads, links: pagination_links(ads))

      serializer.serializable_hash.to_json
    end

    post '/ads', allows: %i[user_id ad] do
      result = CreateAdService.call(
        ad: params[:ad],
        user_id: user_id
      )

      if result.success?
        AdSerializer.new(result.ad).serializable_hash.to_json
      else
        error_response(result.ad, 400)
      end
    end

    put '/ads/:id', allows: %i[id lat lon] do
      raise Auth::Unauthorized unless request.env['HTTP_AUTHORIZATION'] == ENV['GEOCODER_SECRET']

      Ad.find(params[:id]).update(lat: params[:lat], lon: params[:lon])
      logger.info('updating ad coordinates', ad_id: params[:id], lat: params[:lat], lon: params[:lon])
    end
  end
end
