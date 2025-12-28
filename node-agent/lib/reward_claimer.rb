require 'httparty'
require 'json'
require 'eth'
require 'digest'
require_relative 'rpc_client'

module VPNNode
  class RewardClaimer
    DEFAULT_GAS_LIMIT = 500_000
    POLYGON_AMOY_CHAIN_ID = 80002

    def initialize(signer, backend_url, rpc_url, contract_address, contract_abi_path = nil, api_key = nil)
      @signer = signer
      @backend_url = backend_url
      @contract_address = contract_address
      @contract_abi = load_contract_abi(contract_abi_path)
      @rpc = RPCClient.new(rpc_url, api_key || ENV['TATUM_API_KEY'])
      @key = Eth::Key.new(priv: @signer.private_key)
      @chain_id = POLYGON_AMOY_CHAIN_ID
    end

    def fetch_proof(epoch)
      response = HTTParty.get(
        "#{@backend_url}/rewards/proof",
        query: {
          node: @signer.address,
          epoch: epoch
        },
        headers: { 'Content-Type' => 'application/json' }
      )

      unless response.success?
        puts "Failed to fetch proof: #{response.code} - #{response.body}"
        return nil
      end

      JSON.parse(response.body)
    rescue => e
      puts "Error fetching proof: #{e.message}"
      nil
    end

    def claim_reward(epoch)
      puts "Claiming reward for epoch #{epoch}..."

      # 1. Fetch proof from backend
      proof_data = fetch_proof(epoch)
      return false unless proof_data

      # 2. Verify proof data
      unless verify_proof_data(proof_data)
        puts "Invalid proof data"
        return false
      end

      # 3. Check if already claimed
      if already_claimed?(epoch)
        puts "Reward already claimed for epoch #{epoch}"
        return true
      end

      # 4. Build transaction data
      amount = proof_data['amount'].to_i
      proof = proof_data['proof'].map { |p| p.start_with?('0x') ? p : "0x#{p}" }

      # 5. Build, sign and send transaction
      begin
        # Encode function call
        function_data = encode_claim_reward_call(epoch, amount, proof)

        puts "📝 Building transaction..."
        puts "   Contract: #{@contract_address}"
        puts "   Function data: #{function_data[0..100]}..."

        # Get transaction parameters
        nonce = get_nonce
        gas_price = get_gas_price
        gas_limit = estimate_gas(@contract_address, function_data)

        puts "⛽ Gas: price=#{gas_price}, limit=#{gas_limit}, estimated cost=#{(gas_price * gas_limit) / 1e18} MATIC"

        # Build transaction
        transaction = build_transaction(@contract_address, function_data, nonce, gas_price, gas_limit)

        # Sign transaction
        signed_tx = sign_transaction(transaction)

        # Send transaction
        tx_hash = send_transaction(signed_tx)

        puts "✅ Transaction sent!"
        puts "   TX Hash: #{tx_hash}"
        puts "   Explorer: https://amoy.polygonscan.com/tx/#{tx_hash}"

        # Wait for receipt
        receipt = wait_for_receipt(tx_hash)

        if receipt && receipt['status'] == '0x1'
          puts "✅ Reward claimed successfully!"
          puts "   Block: #{receipt['blockNumber']}"
          puts "   Gas used: #{receipt['gasUsed'].to_i(16)}"
          true
        else
          puts "❌ Transaction failed"
          false
        end
      rescue => e
        puts "❌ Failed to claim reward: #{e.message}"
        puts e.backtrace.first(5)
        false
      end
    end

    def check_available_rewards
      response = HTTParty.get("#{@backend_url}/rewards/epochs")
      return [] unless response.success?

      epochs = JSON.parse(response.body)

      # Filter epochs that are committed and not yet claimed
      epochs.select { |e| e['status'] == 'committed' }
    end

    def get_pending_rewards
      available_epochs = check_available_rewards
      pending = []

      available_epochs.each do |epoch|
        epoch_id = epoch['epoch_id']

        # Check if we have a reward for this epoch
        proof_data = fetch_proof(epoch_id)
        next unless proof_data

        # Check if already claimed on-chain
        next if already_claimed?(epoch_id)

        pending << {
          epoch: epoch_id,
          amount: proof_data['amount'],
          start_time: epoch['start_time'],
          end_time: epoch['end_time']
        }
      end

      pending
    end

    private

    def load_contract_abi(path)
      if path && File.exist?(path)
        JSON.parse(File.read(path))
      else
        # Default ABI for Reward contract
        [
          {
            "inputs": [
              { "name": "epoch", "type": "uint256" },
              { "name": "amount", "type": "uint256" },
              { "name": "proof", "type": "bytes32[]" }
            ],
            "name": "claimReward",
            "outputs": [],
            "stateMutability": "nonpayable",
            "type": "function"
          },
          {
            "inputs": [
              { "name": "epoch", "type": "uint256" },
              { "name": "recipient", "type": "address" }
            ],
            "name": "claimed",
            "outputs": [{ "name": "", "type": "bool" }],
            "stateMutability": "view",
            "type": "function"
          }
        ]
      end
    end

    def get_contract
      # TODO: Implement contract interaction
      # eth gem doesn't have full contract support
      # Would need web3-eth or similar
      nil
    end

    def already_claimed?(epoch)
      begin
        # Encode function call for claimed(uint256,address)
        function_data = encode_claimed_call(epoch, @signer.address)

        # Call contract
        result = @rpc.eth_call(@contract_address, function_data)

        # Result is a hex boolean: 0x0000...0000 (false) or 0x0000...0001 (true)
        result.to_i(16) > 0
      rescue => e
        puts "⚠️  Could not check if already claimed: #{e.message}"
        false
      end
    end

    def verify_proof_data(proof_data)
      required_keys = ['epoch', 'node', 'amount', 'proof']
      required_keys.all? { |key| proof_data.key?(key) } &&
        proof_data['node'].downcase == @signer.address.downcase &&
        proof_data['proof'].is_a?(Array) &&
        proof_data['amount'].to_i > 0
    end

    # Encode claimReward(uint256,uint256,bytes32[]) function call
    def encode_claim_reward_call(epoch, amount, proof)
      # Function selector: keccak256("claimReward(uint256,uint256,bytes32[])")[0:4]
      # Using keccak256 from eth gem
      function_sig = "claimReward(uint256,uint256,bytes32[])"
      selector = "0x" + Digest::SHA3.hexdigest(function_sig, 256)[0..7]

      # Encode parameters
      encoded_epoch = encode_uint256(epoch)
      encoded_amount = encode_uint256(amount)
      encoded_proof = encode_bytes32_array(proof)

      "#{selector}#{encoded_epoch}#{encoded_amount}#{encoded_proof}"
    end

    # Encode claimed(uint256,address) function call
    def encode_claimed_call(epoch, address)
      # Function selector: keccak256("claimed(uint256,address)")[0:4]
      function_sig = "claimed(uint256,address)"
      selector = "0x" + Digest::SHA3.hexdigest(function_sig, 256)[0..7]

      encoded_epoch = encode_uint256(epoch)
      encoded_address = encode_address(address)

      "#{selector}#{encoded_epoch}#{encoded_address}"
    end

    # Encode uint256 parameter
    def encode_uint256(value)
      value.to_i.to_s(16).rjust(64, '0')
    end

    # Encode address parameter
    def encode_address(address)
      addr = address.to_s
      addr = addr[2..-1] if addr.start_with?('0x')
      addr.downcase.rjust(64, '0')
    end

    # Encode bytes32[] array
    def encode_bytes32_array(array)
      # For dynamic arrays, we need:
      # 1. Offset to array data (32 bytes)
      # 2. Length of array (32 bytes)
      # 3. Array elements (each 32 bytes)

      offset = "0000000000000000000000000000000000000000000000000000000000000060" # 96 in hex = 3 * 32 bytes
      length = encode_uint256(array.length)
      elements = array.map { |p| encode_bytes32(p) }.join

      "#{offset}#{length}#{elements}"
    end

    # Encode bytes32 (32-byte hex string)
    def encode_bytes32(value)
      val = value.to_s
      val = val[2..-1] if val.start_with?('0x')
      val.rjust(64, '0')
    end

    def get_nonce
      nonce_hex = @rpc.eth_get_transaction_count(@key.address.to_s, 'latest')
      @rpc.hex_to_int(nonce_hex)
    end

    def get_gas_price
      gas_price_hex = @rpc.eth_gas_price
      gas_price = @rpc.hex_to_int(gas_price_hex)
      gas_price > 0 ? gas_price : 30_000_000_000 # Default 30 gwei
    end

    def estimate_gas(contract_address, data)
      transaction_data = {
        from: @key.address.to_s,
        to: contract_address,
        data: data
      }

      begin
        gas_limit_hex = @rpc.eth_estimate_gas(transaction_data)
        gas_limit = @rpc.hex_to_int(gas_limit_hex)
        raise "Gas limit estimation returned 0" if gas_limit == 0
        # Add 20% buffer
        (gas_limit * 1.2).to_i
      rescue => e
        puts "⚠️  Could not estimate gas: #{e.message}, using default"
        DEFAULT_GAS_LIMIT
      end
    end

    def build_transaction(contract_address, data, nonce, gas_price, gas_limit)
      Eth::Tx.new(
        chain_id: @chain_id,
        nonce: nonce,
        gas_price: gas_price,
        gas_limit: gas_limit,
        to: contract_address,
        data: data[2..-1] # Remove 0x prefix
      )
    end

    def sign_transaction(transaction)
      transaction.sign(@key)
      signed_tx = transaction.hex
      signed_tx.start_with?('0x') ? signed_tx : "0x#{signed_tx}"
    end

    def send_transaction(signed_tx)
      @rpc.eth_send_raw_transaction(signed_tx)
    end

    def wait_for_receipt(tx_hash, max_wait = 60)
      puts "⏳ Waiting for transaction confirmation..."
      start_time = Time.now

      while Time.now - start_time < max_wait
        sleep 2
        receipt = @rpc.eth_get_transaction_receipt(tx_hash)
        return receipt if receipt && receipt['blockNumber']
        print "."
      end

      puts "\n⚠️  Transaction receipt not found after #{max_wait}s"
      nil
    end
  end
end

