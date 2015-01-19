require 'faraday'

require 'faraday/overrides/request'
require 'faraday/overrides/rack_builder'
require 'faraday/http_cache/storage'
require 'faraday/http_cache/response'

module Faraday
  # Public: The middleware responsible for caching and serving responses.
  # The middleware use the provided configuration options to establish a
  # 'Faraday::HttpCache::Storage' to cache responses retrieved by the stack
  # adapter. If a stored response can be served again for a subsequent
  # request, the middleware will return the response instead of issuing a new
  # request to it's server. This middleware should be the last attached handler
  # to your stack, so it will be closest to the inner app, avoiding issues
  # with other middlewares on your stack.
  #
  # Examples:
  #
  #   # Using the middleware with a simple client:
  #   client = Faraday.new do |builder|
  #     builder.user :http_cache, store: my_store_backend
  #     builder.adapter Faraday.default_adapter
  #   end
  #
  #   # Attach a Logger to the middleware.
  #   client = Faraday.new do |builder|
  #     builder.use :http_cache, logger: my_logger_instance, store: my_store_backend
  #     builder.adapter Faraday.default_adapter
  #   end
  #
  #   # Provide an existing CacheStore (for instance, from a Rails app)
  #   client = Faraday.new do |builder|
  #     builder.use :http_cache, store: Rails.cache
  #   end
  #
  #   # Use Marshal for serialization
  #   client = Faraday.new do |builder|
  #     builder.use :http_cache, store: Rails.cache, serializer: Marshal
  #   end
  class HttpCache < Faraday::Middleware
    # Internal: valid options for the 'initialize' configuration Hash.
    VALID_OPTIONS = [:store, :serializer, :logger, :expiration, :store_options]

    # Public: Initializes a new HttpCache middleware.
    #
    # app  - the next endpoint on the 'Faraday' stack.
    # args - aditional options to setup the logger and the storage.
    #             :logger        - A logger object.
    #             :serializer    - A serializer that should respond to 'dump' and 'load'.
    #             :store         - A cache store that should respond to 'read' and 'write'.
    #
    # Examples:
    #
    #   # Initialize the middleware with a logger.
    #   Faraday::HttpCache.new(app, logger: my_logger)
    #
    #   # Initialize the middleware with a logger and Marshal as a serializer
    #   Faraday:HttpCache.new(app, logger: my_logger, serializer: Marshal)
    #
    #   # Initialize the middleware with a FileStore at the 'tmp' dir.
    #   store = ActiveSupport::Cache.lookup_store(:file_store, ['tmp'])
    #   Faraday::HttpCache.new(app, store: store)
    #
    #   # Initialize the middleware with a MemoryStore and logger
    #   store = ActiveSupport::Cache.lookup_store
    #   Faraday::HttpCache.new(app, store: store, logger: my_logger)
    def initialize(app, *args)
      super(app)
      @logger = nil

      if args.first.is_a? Hash
        options = args.first
        @logger = options[:logger]
      else
        options = parse_deprecated_options(*args)
      end

      assert_valid_options!(options)
      @storage = create_storage(options)
    end

    # Public: Process the request into a duplicate of this instance to
    # ensure that the internal state is preserved.
    def call(env)
      dup.call!(env)
    end

    # Internal: Process the stack request to try to serve a cache response.
    # On a cacheable request, the middleware will attempt to locate a
    # valid stored response to serve. On a cache miss, the middleware will
    # forward the request and try to store the response for future requests.
    # If the request can't be cached, the request will be delegated directly
    # to the underlying app and does nothing to the response.
    # The processed steps will be recorded to be logged once the whole
    # process is finished.
    #
    # Returns a 'Faraday::Response' instance.
    def call!(env)
      @trace = []
      @request = create_request(env)

      response = process(env)

      response.on_complete do
        log_request
      end
    end

    protected

    # Internal: Gets the request object created from the Faraday env Hash.
    attr_reader :request

    # Internal: Gets the storage instance associated with the middleware.
    attr_reader :storage

    # Public: Creates the Storage instance for this middleware.
    #
    # options - A Hash of options.
    #
    # Returns a Storage instance.
    def create_storage(options)
      Storage.new(options)
    end

    private

    # Internal: Receive the deprecated arguments to initialize the old API
    # and returns a Hash compatible with the new API
    #
    # Examples:
    #
    #   parse_deprecated_options(Rails.cache)
    #   # => { store: Rails.cache }
    #
    #   parse_deprecated_options(:mem_cache_store)
    #   # => { store: :mem_cache_store }
    #
    #   parse_deprecated_options(:mem_cache_store, logger: Rails.logger)
    #   # => { store: :mem_cache_store, logger: Rails.logger }
    #
    #   parse_deprecated_options(:mem_cache_store, 'localhost:11211')
    #   # => { store: :mem_cache_store, store_options: ['localhost:11211] }
    #
    #   parse_deprecated_options(:mem_cache_store, logger: Rails.logger, serializer: Marshal)
    #   # => { store: :mem_cache_store, logger: Rails.logger, serializer: Marshal }
    #
    #   parse_deprecated_options(serializer: Marshal)
    #   # => { serializer: Marshal }
    #
    #   parse_deprecated_options(:file_store, { serializer: Marshal }, 'tmp')
    #   # => { store: :file_store, serializer: Marshal, store_options: ['tmp'] }
    #
    #   parse_deprecated_options(:memory_store, size: 1024)
    #   # => { store: :memory_store, store_options: [size: 1024] }
    #
    # Returns a hash with the following keys:
    #   - store
    #   - serializer
    #   - logger
    #   - store_options
    #
    # In order to check what each key means, check `Storage#initialize` description.
    def parse_deprecated_options(*args)
      options = {}
      if args.length > 0
        Kernel.warn('DEPRECATION WARNING: This API is deprecated, refer to the documentation for the new one', caller)
      end

      options[:store] = args.shift

      if args.first.is_a? Hash
        hash_params = args.first
        options[:serializer] = hash_params.delete(:serializer)

        @logger = hash_params[:logger]
        @should_cache = hash_params.fetch(:should_cache, true)
      end

      options[:store_options] = args
      options
    end

    # Internal: Tries to locate a valid response or forwards the call to the stack.
    # * If no entry is present on the storage, the 'fetch' method will forward
    # the call to the remaining stack and return the new response.
    # * If a fresh response is found, the middleware will abort the remaining
    # stack calls and return the stored response back to the client.
    # * If a response is found but isn't fresh anymore, the middleware will
    # revalidate the response back to the server.
    #
    # env - the environment 'Hash' provided from the 'Faraday' stack.
    #
    # Returns the 'Faraday::Response' instance to be served.
    def process(env)
      entry = @storage.read(@request)

      return fetch(env) if env[:force_no_cache] or entry.nil?
      entry.to_response(env)
    end

    # Internal: Records a traced action to be used by the logger once the
    # request/response phase is finished.
    #
    # operation - the name of the performed action, a String or Symbol.
    #
    # Returns nothing.
    def trace(operation)
      @trace << operation
    end

    # Internal: Stores the response into the storage.
    # If the response isn't cacheable, a trace action 'invalid' will be
    # recorded for logging purposes.
    #
    # response - a 'Faraday::HttpCache::Response' instance to be stored.
    #
    # Returns nothing.
    def store(response)
      trace :store
      @storage.write(@request, response)
    end

    # Internal: Fetches the response from the Faraday stack and stores it.
    #
    # env - the environment 'Hash' from the Faraday stack.
    #
    # Returns the fresh 'Faraday::Response' instance.
    def fetch(env)
      trace :miss
      @app.call(env).on_complete do |fresh_env|
        response = Response.new(create_response(fresh_env))
        store(response)
      end
    end

    # Internal: Creates a new 'Hash' containing the response information.
    #
    # env - the environment 'Hash' from the Faraday stack.
    #
    # Returns a 'Hash' containing the ':status', ':body' and 'response_headers'
    # entries.
    def create_response(env)
      hash = env.to_hash

      {
        status: hash[:status],
        body: hash[:body],
        response_headers: hash[:response_headers]
      }
    end

    # Internal: Creates a new 'Hash' containing the request information.
    #
    # env - the environment 'Hash' from the Faraday stack.
    #
    # Returns a 'Hash' containing the ':method', ':url' and 'request_headers'
    # entries.
    def create_request(env)
      hash = env.to_hash

      {
        method: hash[:method],
        url: hash[:url],
        request_headers: hash[:request_headers].dup,
        body: hash[:body]
      }
    end

    # Internal: Logs the trace info about the incoming request
    # and how the middleware handled it.
    # This method does nothing if theresn't a logger present.
    #
    # Returns nothing.
    def log_request
      return unless @logger

      method = @request[:method].to_s.upcase
      path = @request[:url].request_uri
      line = "HTTP Cache: [#{method} #{path}] #{@trace.join(', ')}"
      @logger.debug(line)
    end

    # Internal: Checks if the given 'options' Hash contains only
    # valid keys. Please see the 'VALID_OPTIONS' constant for the
    # acceptable keys.
    #
    # Raises an 'ArgumentError'.
    #
    # Returns nothing.
    def assert_valid_options!(options)
      options.each_key do |key|
        unless VALID_OPTIONS.include?(key)
          raise ArgumentError.new("Unknown option: #{key}. Valid options are :#{VALID_OPTIONS.join(', ')}")
        end
      end
    end
  end
end

if Faraday.respond_to?(:register_middleware)
  Faraday.register_middleware http_cache: Faraday::HttpCache
elsif Faraday::Middleware.respond_to?(:register_middleware)
  Faraday::Middleware.register_middleware http_cache: Faraday::HttpCache
end
