require 'httparty'
require 'json'

module VPNNode
  class RewardVerifier
    def initialize(signer, backend_url)
      @signer = signer
      @backend_url = backend_url
    end

    def verify_reward(epoch_id)
      puts "Verifying reward for epoch #{epoch_id}..."

      response = HTTParty.get(
        "#{@backend_url}/rewards/verify/#{epoch_id}",
        query: { node: @signer.address },
        headers: { 'Content-Type' => 'application/json' }
      )

      unless response.success?
        puts "Failed to fetch reward data: #{response.code} - #{response.body}"
        return false
      end

      data = JSON.parse(response.body)

      # Verify node address matches
      unless data['node'].downcase == @signer.address.downcase
        puts "❌ Node address mismatch!"
        return false
      end

      # Verify traffic records signatures
      puts "Verifying #{data['traffic_records'].length} traffic record(s)..."
      invalid_records = []

      data['traffic_records'].each do |record|
        # TODO: Implement full signature verification
        # For now, just check that signature exists
        unless record['signature'] && record['signature'].length > 0
          invalid_records << record['id']
        end
      end

      if invalid_records.any?
        puts "❌ Found #{invalid_records.length} invalid traffic record(s): #{invalid_records.join(', ')}"
        return false
      end

      # Check reward calculation match
      if data['reward_calculation']['match']
        puts "✅ Reward calculation verified!"
        puts "   Calculated: #{data['reward_calculation']['calculated_amount']} DEVPN"
        puts "   Actual: #{data['reward_calculation']['actual_amount']} DEVPN"
        puts "   Traffic: #{data['metrics']['total_traffic_mb']} MB"
        puts "   Quality: #{data['metrics']['quality_score']}"
        puts "   Reputation: #{data['metrics']['reputation_score']}"
        return true
      else
        puts "❌ Reward calculation mismatch!"
        puts "   Calculated: #{data['reward_calculation']['calculated_amount']} DEVPN"
        puts "   Actual: #{data['reward_calculation']['actual_amount']} DEVPN"
        return false
      end
    rescue => e
      puts "Error verifying reward: #{e.message}"
      puts e.backtrace.first(3)
      false
    end
  end
end

