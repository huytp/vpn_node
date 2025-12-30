require 'uri'
require 'net/http'
require 'json'

module VPNNode
  class RPCClient
    # Rate limiting: 3 requests per second (Tatum free tier limit)
    MAX_REQUESTS_PER_SECOND = 3
    MIN_INTERVAL_BETWEEN_REQUESTS = 1.0 / MAX_REQUESTS_PER_SECOND # ~0.333 seconds

    # Retry configuration for 429 errors
    MAX_RETRIES = 5
    INITIAL_RETRY_DELAY = 1.0 # seconds
    MAX_RETRY_DELAY = 60.0 # seconds

    # Class-level rate limiter (shared across all instances)
    @@last_request_time = nil
    @@rate_limiter_mutex = Mutex.new

    def initialize(rpc_url, api_key = nil)
      @rpc_url = rpc_url
      @api_key = api_key || ENV['TATUM_API_KEY']
      @request_id = 0
    end

    def call(method, params = [], retry_count = 0)
      @request_id += 1

      payload = {
        jsonrpc: '2.0',
        id: @request_id,
        method: method,
        params: params
      }

      # Rate limiting: ensure we don't exceed MAX_REQUESTS_PER_SECOND
      enforce_rate_limit

      uri = URI(@rpc_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
      request['accept'] = 'application/json'
      request['content-type'] = 'application/json'
      request['x-api-key'] = @api_key if @api_key
      request.body = payload.to_json

      response = http.request(request)

      # Handle 429 (rate limit) errors with retry and exponential backoff
      if response.code == '429'
        if retry_count < MAX_RETRIES
          delay = calculate_retry_delay(retry_count)
          puts "⚠️  Rate limit hit (429) for #{method}. Retrying in #{delay}s (attempt #{retry_count + 1}/#{MAX_RETRIES})"
          sleep(delay)
          return call(method, params, retry_count + 1)
        else
          raise "RPC call failed after #{MAX_RETRIES} retries: #{response.code} - #{response.body}"
        end
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "RPC call failed: #{response.code} - #{response.body}"
      end

      result = JSON.parse(response.body)

      if result['error']
        raise "RPC error: #{result['error']['message']} (code: #{result['error']['code']})"
      end

      result['result']
    end

    # Convenience methods for common RPC calls
    def eth_block_number
      call('eth_blockNumber')
    end

    def eth_get_balance(address, block = 'latest')
      call('eth_getBalance', [address, block])
    end

    def eth_get_transaction_count(address, block = 'latest')
      call('eth_getTransactionCount', [address, block])
    end

    def eth_gas_price
      call('eth_gasPrice')
    end

    def eth_estimate_gas(transaction)
      call('eth_estimateGas', [transaction])
    end

    def eth_send_raw_transaction(signed_tx)
      call('eth_sendRawTransaction', [signed_tx])
    end

    def eth_call(to, data, block = 'latest')
      call('eth_call', [{ to: to, data: data }, block])
    end

    def eth_get_transaction_receipt(tx_hash)
      call('eth_getTransactionReceipt', [tx_hash])
    end

    def eth_chain_id
      call('eth_chainId')
    end

    def hex_to_int(hex_string)
      hex_string.to_i(16)
    end

    def int_to_hex(int)
      "0x#{int.to_s(16)}"
    end

    private

    def enforce_rate_limit
      @@rate_limiter_mutex.synchronize do
        if @@last_request_time
          time_since_last_request = Time.now - @@last_request_time
          if time_since_last_request < MIN_INTERVAL_BETWEEN_REQUESTS
            sleep_time = MIN_INTERVAL_BETWEEN_REQUESTS - time_since_last_request
            sleep(sleep_time) if sleep_time > 0
          end
        end
        @@last_request_time = Time.now
      end
    end

    def calculate_retry_delay(retry_count)
      # Exponential backoff: 1s, 2s, 4s, 8s, 16s, capped at MAX_RETRY_DELAY
      delay = INITIAL_RETRY_DELAY * (2 ** retry_count)
      delay = [delay, MAX_RETRY_DELAY].min
      # Add small random jitter to avoid thundering herd
      delay + (rand * 0.5)
    end
  end
end

