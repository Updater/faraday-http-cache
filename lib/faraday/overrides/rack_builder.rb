module Faraday
  class RackBuilder
    alias_method :orig_build_env, :build_env

    def build_env(connection, request)
      original_env = orig_build_env(connection, request)
      original_env[:force_no_cache] = !!request.force_no_cache
      original_env
    end
  end
end
