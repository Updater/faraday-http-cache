require 'rubygems'
require 'bundler/setup'

require 'faraday/http_cache'
require 'active_support/logger'

require 'redis'

redis_store = Redis.new(host:'127.0.0.1', port:6379, namespace: 'test')

client = Faraday.new('http://api.staging.v4.updater.com/v1') do |stack|
  stack.use :http_cache, logger: ActiveSupport::Logger.new(STDOUT), store: redis_store, expiration: 10
  stack.adapter Faraday.default_adapter
end

[10, 20, 30, 10, 20].each_with_index do |item, index|
  started = Time.now
  puts "Request ##{index+1}"
  puts "body: #{item}"
  response = client.post do |req|
    req.url 'debug/clock'
    req.body = item.to_s
  end

  finished = Time.now
  puts "  Request took #{(finished - started) * 1000} ms."
  puts "  #{response}"
end
