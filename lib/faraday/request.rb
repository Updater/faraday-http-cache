module Faraday
  class Request
    alias_method :orig_to_env, :to_env
    def no_cache!
      @force_no_cache = false
    end

    def to_env(connection)
      original_env = orig_to_env(connection)
      original_env[:force_no_cache] = force_no_cache
      original_env
    end
  end
end
