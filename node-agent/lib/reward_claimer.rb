require 'httparty'
require 'json'
require 'eth'
require 'digest/keccak'
require_relative 'rpc_client'

module VPNNode
  class RewardClaimer
    DEFAULT_GAS_LIMIT = 300_000
    POLYGON_AMOY_CHAIN_ID = 80_002

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

      proof_data = JSON.parse(response.body)

      # Log proof data for debugging
      puts "   📥 Proof data from backend:"
      puts "      Epoch: #{proof_data['epoch']}"
      puts "      Node: #{proof_data['node']}"
      puts "      Amount: #{proof_data['amount']}"
      puts "      Proof array length: #{proof_data['proof']&.length || 0}"

      proof_data
    rescue => e
      puts "Error fetching proof: #{e.message}"
      puts e.backtrace.first(3) if e.backtrace
      nil
    end

    def claim_reward(epoch)
      puts "🔄 Claiming reward for epoch #{epoch}..."

      # 1. Fetch proof from backend
      proof_data = fetch_proof(epoch)
      unless proof_data
        puts "❌ Failed to fetch proof from backend"
        return { success: false, error: 'Failed to fetch proof' }
      end

      # 2. Verify proof data
      unless verify_proof_data(proof_data)
        puts "❌ Invalid proof data - cannot proceed with claim"
        return { success: false, error: 'Invalid proof data', details: 'Proof validation failed' }
      end

      # 3. Check if already claimed
      if already_claimed?(epoch)
        puts "⚠️  Reward already claimed for epoch #{epoch}"
        # Update backend status
        update_claimed_status(epoch, true)
        return { success: true, already_claimed: true, epoch: epoch }
      end

      # 4. Build transaction data
      amount = proof_data['amount'].to_i
      proof = proof_data['proof'].map { |p| p.start_with?('0x') ? p : "0x#{p}" }
      merkle_root = proof_data['merkle_root']

      puts "   📋 Proof data:"
      puts "      Amount: #{amount}"
      puts "      Proof length: #{proof.length}"
      puts "      Merkle root: #{merkle_root}"

      # Verify proof locally before sending transaction
      if merkle_root && !proof.empty?
        if verify_proof_locally(amount, proof, merkle_root)
          puts "   ✅ Local proof verification passed"
        else
          puts "   ⚠️  Local proof verification failed - proof may be invalid"
          puts "      Will still attempt on-chain (contract will reject if invalid)"
        end
      end

      # 5. Claim on blockchain
      begin
        tx_hash = claim_on_blockchain(epoch, amount, proof)

        if tx_hash
          puts "✅ Reward claimed successfully!"
          puts "   Transaction: https://amoy.polygonscan.com/tx/#{tx_hash}"

          # Update backend status
          update_claimed_status(epoch, true, tx_hash)

          return {
            success: true,
            tx_hash: tx_hash,
            amount: amount,
            epoch: epoch,
            node: @signer.address
          }
        else
          puts "❌ Transaction failed on blockchain"
          return { success: false, error: 'Transaction failed on blockchain' }
        end
      rescue => e
        puts "❌ Failed to claim reward: #{e.message}"
        puts e.backtrace.first(5)
        return { success: false, error: e.message }
      end
    end

    # Claim reward on blockchain (moved from backend)
    def claim_on_blockchain(epoch_id, amount, proof_array)
      unless @contract_address
        raise "Missing REWARD_CONTRACT_ADDRESS"
      end

      puts "📝 Building claim transaction..."
      puts "   Contract: #{@contract_address}"
      puts "   Node: #{@signer.address}"
      puts "   Epoch: #{epoch_id}"
      puts "   Amount: #{amount}"
      puts "   Proof elements: #{proof_array.length}"

      # Function selector for claimReward(uint256,uint256,bytes32[])
      function_selector = "0x" + calculate_claim_reward_selector

      # Encode parameters
      encoded_params = encode_claim_reward_params(epoch_id, amount, proof_array)

      # Build transaction data
      function_data = "#{function_selector}#{encoded_params}"

      # Get transaction parameters
      nonce_hex = @rpc.eth_get_transaction_count(@key.address.to_s, 'latest')
      nonce = @rpc.hex_to_int(nonce_hex)

      gas_price_hex = @rpc.eth_gas_price
      gas_price = @rpc.hex_to_int(gas_price_hex)
      gas_price = 30_000_000_000 if gas_price == 0 # Default 30 gwei

      # Estimate gas
      begin
        gas_limit_hex = @rpc.eth_estimate_gas({
          from: @key.address.to_s,
          to: @contract_address,
          data: function_data
        })
        gas_limit = @rpc.hex_to_int(gas_limit_hex)
        gas_limit = (gas_limit * 1.2).to_i # Add 20% buffer
      rescue => e
        puts "⚠️  Gas estimation failed: #{e.message}, using default"
        gas_limit = DEFAULT_GAS_LIMIT
      end

      # Check balance before attempting transaction
      balance_hex = @rpc.eth_get_balance(@key.address.to_s, 'latest')
      balance_wei = @rpc.hex_to_int(balance_hex)
      estimated_gas_cost = gas_price * gas_limit
      balance_matic = balance_wei / 1_000_000_000_000_000_000.0 # Convert wei to MATIC
      estimated_cost_matic = estimated_gas_cost / 1_000_000_000_000_000_000.0

      puts "💰 Balance: #{balance_matic.round(6)} MATIC"
      puts "⛽ Gas: price=#{gas_price}, limit=#{gas_limit}, estimated_cost=#{estimated_cost_matic.round(6)} MATIC"

      if balance_wei < estimated_gas_cost
        error_msg = "❌ Insufficient funds! Need #{estimated_cost_matic.round(6)} MATIC for gas, but only have #{balance_matic.round(6)} MATIC"
        puts error_msg
        puts "💡 Please fund your wallet at: #{@key.address.to_s}"
        puts "   Polygon Amoy Faucet: https://faucet.polygon.technology/"
        raise error_msg
      end

      # Build transaction
      transaction = Eth::Tx.new(
        chain_id: @chain_id,
        nonce: nonce,
        gas_price: gas_price,
        gas_limit: gas_limit,
        to: @contract_address,
        data: function_data[2..-1] # Remove 0x prefix
      )

      # Sign transaction
      transaction.sign(@key)
      signed_tx = transaction.hex
      signed_tx = "0x#{signed_tx}" unless signed_tx.start_with?('0x')

      # Send transaction
      begin
        tx_hash = @rpc.eth_send_raw_transaction(signed_tx)
        puts "📤 Transaction sent: #{tx_hash}"
      rescue => e
        if e.message.include?('insufficient funds')
          error_msg = "❌ Insufficient funds to send transaction!"
          puts error_msg
          puts "💰 Current balance: #{balance_matic.round(6)} MATIC"
          puts "⛽ Required: #{estimated_cost_matic.round(6)} MATIC"
          puts "💡 Please fund your wallet at: #{@key.address.to_s}"
          puts "   Polygon Amoy Faucet: https://faucet.polygon.technology/"
          raise error_msg
        else
          raise
        end
      end

      # Wait for receipt
      receipt = wait_for_receipt(tx_hash, 60)
      if receipt && receipt['status'] == '0x1'
        puts "✅ Transaction confirmed!"
        puts "   Block: #{receipt['blockNumber']}, Gas used: #{receipt['gasUsed'].to_i(16)}"
        return tx_hash
      else
        puts "❌ Transaction failed on blockchain"
        puts "   Transaction hash: #{tx_hash}"
        puts "   🔗 View on explorer: https://amoy.polygonscan.com/tx/#{tx_hash}"

        if receipt
          status = receipt['status']
          status_int = status.to_i(16) if status
          puts "   Status: #{status} (#{status_int == 0 ? 'Failed/Reverted' : 'Unknown'})"

          # Try to get transaction details
          begin
            tx_details = @rpc.eth_get_transaction_by_hash(tx_hash)
            if tx_details
              puts "   Gas limit: #{@rpc.hex_to_int(tx_details['gas'])}"
              puts "   Gas price: #{@rpc.hex_to_int(tx_details['gasPrice'])}"
            end
          rescue => e
            # Ignore errors when getting transaction details
          end

          # Common reasons for failure
          puts "\n   💡 Possible reasons:"
          puts "      - Reward already claimed for this epoch"
          puts "      - Invalid Merkle proof"
          puts "      - Contract validation failed"
          puts "      - Check transaction details on Polygonscan for revert reason"
        else
          puts "   ⚠️  Could not get transaction receipt"
          puts "      Transaction may still be pending or failed to be included"
        end

        return nil
      end
    end

    # Update claimed status on backend
    def update_claimed_status(epoch_id, claimed, tx_hash = nil)
      begin
        response = HTTParty.post(
          "#{@backend_url}/rewards/update_claimed",
          body: {
            node: @signer.address,
            epoch_id: epoch_id,
            claimed: claimed,
            tx_hash: tx_hash
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

        if response.success?
          puts "✅ Backend status updated"
        else
          puts "⚠️  Failed to update backend status: #{response.code}"
        end
      rescue => e
        puts "⚠️  Error updating backend status: #{e.message}"
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
        claimed = result.to_i(16) > 0
        if claimed
          puts "   ℹ️  Checked on-chain: reward already claimed for epoch #{epoch}"
        end
        claimed
      rescue => e
        # If eth_call fails, it might be because the function doesn't exist or other issues
        # We'll proceed with the claim attempt and let the transaction fail if already claimed
        puts "   ⚠️  Could not check if already claimed on-chain: #{e.message}"
        puts "      Will attempt claim - transaction will revert if already claimed"
        false
      end
    end

    def verify_proof_data(proof_data)
      required_keys = ['epoch', 'node', 'amount', 'proof']

      # Check all required keys exist
      unless required_keys.all? { |key| proof_data.key?(key) }
        missing = required_keys.reject { |key| proof_data.key?(key) }
        puts "   ❌ Missing required keys: #{missing.join(', ')}"
        return false
      end

      # Check node address matches
      unless proof_data['node'].downcase == @signer.address.downcase
        puts "   ❌ Node address mismatch:"
        puts "      Expected: #{@signer.address}"
        puts "      Got: #{proof_data['node']}"
        return false
      end

      # Check proof is an array
      unless proof_data['proof'].is_a?(Array)
        puts "   ❌ Proof is not an array: #{proof_data['proof'].class}"
        return false
      end

      # Check proof - empty proof is valid if there's only 1 node in the epoch
      # (in that case, root == leaf, so no proof needed)
      if proof_data['proof'].empty?
        puts "   ⚠️  Proof array is empty"
        puts "      This is valid if epoch has only 1 node (root == leaf)"
        puts "      Will attempt claim with empty proof array"
        # Don't reject - allow empty proof for single-node epochs
      end

      # Check amount is positive
      unless proof_data['amount'].to_i > 0
        puts "   ❌ Invalid amount: #{proof_data['amount']}"
        return false
      end

      true
    end

    # Function selector for claimReward(uint256,uint256,bytes32[])
    def calculate_claim_reward_selector
      "91e3ca0b" # keccak256("claimReward(uint256,uint256,bytes32[])")
    end

    # Encode parameters for claimReward(uint256 epoch, uint256 amount, bytes32[] proof)
    def encode_claim_reward_params(epoch, amount, proof_array)
      # ABI encoding for: (uint256 epoch, uint256 amount, bytes32[] proof)
      # Offset 0: epoch (uint256)
      # Offset 32: amount (uint256)
      # Offset 64: offset to proof array (uint256) = 96 (0x60)
      # Offset 96: proof array length (uint256)
      # Offset 128+: proof array elements (bytes32[])

      encoded_epoch = encode_uint256(epoch)
      encoded_amount = encode_uint256(amount)
      proof_offset = encode_uint256(96) # Offset to dynamic array
      proof_length = encode_uint256(proof_array.length)

      # Encode each proof element
      encoded_proof_elements = proof_array.map do |proof_hex|
        encode_bytes32(proof_hex)
      end.join

      "#{encoded_epoch}#{encoded_amount}#{proof_offset}#{proof_length}#{encoded_proof_elements}"
    end

    # Legacy method for compatibility
    def encode_claim_reward_call(epoch, amount, proof)
      function_selector = "0x" + calculate_claim_reward_selector
      encoded_params = encode_claim_reward_params(epoch, amount, proof)
      "#{function_selector}#{encoded_params}"
    end

    # Encode claimed(uint256,address) function call
    def encode_claimed_call(epoch, address)
      # Function selector: keccak256("claimed(uint256,address)")[0:4]
      function_sig = "claimed(uint256,address)"
      hash = Digest::Keccak.hexdigest(function_sig, 256)
      selector = "0x" + hash[0..7]

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

    def encode_uint256(value)
      value.to_i.to_s(16).rjust(64, '0')
    end

    def encode_bytes32(value)
      val = value.to_s
      val = val[2..-1] if val.start_with?('0x')
      val.rjust(64, '0')
    end

    # Verify Merkle proof locally (matches contract logic)
    def verify_proof_locally(amount, proof_array, merkle_root)
      begin
        # Calculate leaf hash (same as contract: keccak256(abi.encodePacked(recipient, amount)))
        address_hex = @signer.address.to_s
        address_hex = address_hex[2..-1] if address_hex.start_with?('0x')
        address_bytes = [address_hex].pack('H*')

        amount_hex = amount.to_s(16).rjust(64, '0')
        amount_bytes = [amount_hex].pack('H*')

        packed = address_bytes + amount_bytes
        leaf = Digest::Keccak.hexdigest(packed, 256)

        # Verify proof (matches contract logic)
        computed_hash = leaf
        proof_array.each do |proof_element|
          proof_hex = proof_element.to_s
          proof_hex = proof_hex[2..-1] if proof_hex.start_with?('0x')

          # Contract logic: if (computedHash < proof[i]) then left first, else right first
          if computed_hash < proof_hex
            # hash(computedHash, proof[i])
            left_bytes = [computed_hash].pack('H*')
            right_bytes = [proof_hex].pack('H*')
            packed = left_bytes + right_bytes
          else
            # hash(proof[i], computedHash)
            left_bytes = [proof_hex].pack('H*')
            right_bytes = [computed_hash].pack('H*')
            packed = left_bytes + right_bytes
          end

          computed_hash = Digest::Keccak.hexdigest(packed, 256)
        end

        # Compare with root
        root_hex = merkle_root.to_s
        root_hex = root_hex[2..-1] if root_hex.start_with?('0x')

        result = computed_hash.downcase == root_hex.downcase
        unless result
          puts "      Computed: #{computed_hash}"
          puts "      Expected: #{root_hex}"
        end
        result
      rescue => e
        puts "      ⚠️  Error verifying proof locally: #{e.message}"
        false
      end
    end
  end
end

