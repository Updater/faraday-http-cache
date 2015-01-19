module Faraday
  class Request
    attr_reader :force_no_cache

    def no_cache!
      @force_no_cache = true
    end
  end
end
