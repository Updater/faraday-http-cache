require 'spec_helper'

describe Faraday::HttpCache do
  let(:logger) { double('a Logger object', debug: nil, warn: nil) }
  let(:options) { { logger: logger } }
  let(:request_body) { '' }

  let(:client) do
    Faraday.new(url: ENV['FARADAY_SERVER']) do |stack|
      stack.use Faraday::HttpCache, options
      adapter = ENV['FARADAY_ADAPTER']
      stack.headers['X-Faraday-Adapter'] = adapter
      stack.adapter adapter.to_sym
    end
  end

  before do
    client.get('clear')
  end

  it 'caches the GET request' do
    client.get('get')
    expect(client.get('get').body).to eq('1')
  end

  context 'when specifying an expiration time' do

    let(:options) { { logger: logger, expiration: expiration } }
    let(:expiration) { 1 }

    it 'overides the default expiration time' do
      client.get('get')
      sleep expiration
      expect(client.get('get').body).to eq('2')
    end
  end

  context 'when making POST' do

    it 'caches the POST request' do
      client.post do |req|
        req.url 'post'
        req.body = request_body
      end

      res = client.post do |req|
        req.url 'post'
        req.body = request_body
      end

      expect(res.body).to eq('1')
    end

    context 'with different bodies' do

      it 'makes a separate request' do
        client.post do |req|
          req.url 'post'
          req.body = request_body
        end

        res = client.post do |req|
          req.url 'post'
          req.body = request_body + 'notthesame'
        end

        expect(res.body).to eq('2')
      end
    end

  end

  it 'raises an error when misconfigured' do
    expect {
      client = Faraday.new(url: ENV['FARADAY_SERVER']) do |stack|
        stack.use Faraday::HttpCache, i_have_no_idea: true
      end

      client.get('get')
    }.to raise_error(ArgumentError)
  end

  describe 'Configuration options' do
    let(:app) { double('it is an app!') }

    it 'uses the options to create a Cache Store' do
      store = double(read: nil, write: nil)

      expect(Faraday::HttpCache::Storage).to receive(:new).with(store: store)
      Faraday::HttpCache.new(app, store: store)
    end

    it 'accepts a Hash option' do
      expect(ActiveSupport::Cache).to receive(:lookup_store).with(:memory_store, [{ size: 1024 }]).and_call_original
      Faraday::HttpCache.new(app, store: :memory_store, store_options: [size: 1024])
    end

    it 'consumes the "logger" key' do
      expect(ActiveSupport::Cache).to receive(:lookup_store).with(:memory_store, nil).and_call_original
      Faraday::HttpCache.new(app, store: :memory_store, logger: logger)
    end

    context 'with deprecated options format' do
      before do
        allow(Kernel).to receive(:warn)
      end

      it 'uses the options to create a Cache Store' do
        expect(ActiveSupport::Cache).to receive(:lookup_store).with(:file_store, ['tmp']).and_call_original
        Faraday::HttpCache.new(app, :file_store, 'tmp')
      end

      it 'accepts a Hash option' do
        expect(ActiveSupport::Cache).to receive(:lookup_store).with(:memory_store, [{ size: 1024 }]).and_call_original
        Faraday::HttpCache.new(app, :memory_store, size: 1024)
      end

      it 'warns the user about the deprecated options' do
        expect(Kernel).to receive(:warn)

        Faraday::HttpCache.new(app, :memory_store, logger: logger)
      end
    end
  end

  context 'when overriding no cache on per request base' do

    it 'does not cache at all' do
      client.get('get') do |req|
        req.no_cache!
      end
      response = client.get('get') do |req|
        req.no_cache!
      end

      expect(response.body).to eq('2')
    end

  end
end
