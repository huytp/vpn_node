require 'uri'
require 'net/http'
require 'json'

module VPNNode
  class RPCClient
    def initialize(rpc_url, api_key = nil)
      @rpc_url = rpc_url
      @api_key = api_key || ENV['TATUM_API_KEY']
      @request_id = 0
    end

    def call(method, params = [])
      @request_id += 1

      payload = {
        jsonrpc: '2.0',
        id: @request_id,
        method: method,
        params: params
      }

      uri = URI(@rpc_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path)
      request['accept'] = 'application/json'
      request['content-type'] = 'application/json'
      request['x-api-key'] = @api_key if @api_key
      request.body = payload.to_json

      response = http.request(request)

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
  end
end

