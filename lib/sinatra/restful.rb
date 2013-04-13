require 'json'
require 'zlib'
require 'rack/deflater'
require 'rack/throttle'
require 'sinatra/base'

module Sinatra
    module Restful
        VERSION_CHECK = %r{/v([^/]+)} 

        module Throttle
            class Qps < Rack::Throttle::Limiter
                def initialize(app, options = {})
                    super
                end

                # Token bucket algorithm to limit QPS
                # @see http://en.wikipedia.org/wiki/Token_bucket
                def allowed?(request)
                    value = options[:value] || 10

                    key = cache_key(request)
                    time = request_start_time(request)
                    bucket = cache_get(key) rescue nil
                    if bucket == nil
                        bucket = {
                            :time => Time.now.to_i,
                            :tokens => value
                        }
                    end

                    if bucket[:tokens] < value
                        delta = (value * (Time.now.to_i - bucket[:time]))
                        bucket[:tokens] = [value, bucket[:tokens] + (value * delta)].min
                    end
                    bucket[:time] = Time.now.to_i

                    allowed = false
                    if bucket[:tokens] > 0
                        bucket[:tokens] -= 1
                        allowed = true
                    end

                    begin
                        cache_set(key, bucket)
                        allowed
                    rescue
                        # If cache_set fails, just allow the request
                        true
                    end
                end

                def http_error(code, message = nil, headers = {})
                    content = {
                        :error => {
                            :message => message
                        }
                    }

                    [code, {'Content-Type' => 'text/json; charset=utf-8'}.merge(headers),
                    [JSON.generate(content)]]
                end
            end
        end

        class Compress < Rack::Deflater
        end

        def self.registered(app)
            # Condition for matching Accept-Encoding
            def accept_encoding(type, version = nil)
                condition do
                    request.accept_encoding.each do |k, v|
                        if type == k
                            return version == nil || version >= v
                        end
                    end

                    return false
                end
            end

            def version(version)
                condition do
                    # FIXME: If a route with a higher version number is defined
                    # after the older one, the older one will always be matched
                    # first
                    return env.has_key?('sinatra.rest.version') && 
                        env['sinatra.rest.version'] >= version
                end
            end

            app.before VERSION_CHECK do
                match = request.path_info.match(VERSION_CHECK)
                env['sinatra.rest.version'] = match[1]
                request.path_info = match.post_match
            end

            # Return hash for not found response
            app.not_found do
                content = {
                    :error => {
                        :message => env['sinatra.error']
                    }
                }
            end

            # Encode the response as json
            app.after do
                content_type :json
                body JSON.generate(body)
            end
        end
    end

    register Restful
end

