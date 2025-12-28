#!/usr/bin/env ruby

# Quick test for reward_claimer.rb - tests core functionality without network calls

require_relative 'node-agent/lib/vpn_node'

puts "\n" + "="*60
puts "REWARD CLAIMER - QUICK TEST"
puts "="*60

# Setup
key_path = './keys/node.key'
unless File.exist?(key_path)
  puts "Creating test key..."
  VPNNode::Signer.generate_key(key_path)
end

signer = VPNNode::Signer.new(key_path)
puts "✓ Signer initialized: #{signer.address}"

# Initialize claimer
claimer = VPNNode::RewardClaimer.new(
  signer,
  'http://localhost:3000',
  'https://test-rpc',
  '0x1234567890123456789012345678901234567890'
)
puts "✓ RewardClaimer initialized"

# Test verify_proof_data
puts "\nTesting verify_proof_data:"

valid_proof = {
  'epoch' => 1,
  'node' => signer.address,
  'amount' => '1000000000000000000',
  'proof' => ['0x1234', '0x5678']
}

result = claimer.send(:verify_proof_data, valid_proof)
puts result ? "✓ Valid proof verified" : "✗ Valid proof failed"

invalid_proof = {
  'epoch' => 1,
  'node' => '0xDifferent',
  'amount' => '0',
  'proof' => []
}

result = claimer.send(:verify_proof_data, invalid_proof)
puts !result ? "✓ Invalid proof rejected" : "✗ Invalid proof accepted"

# Test ABI loading
puts "\nTesting ABI loading:"
abi = claimer.send(:load_contract_abi, nil)
puts abi.is_a?(Array) && abi.length > 0 ? "✓ Default ABI loaded (#{abi.length} functions)" : "✗ ABI load failed"

puts "\n" + "="*60
puts "Quick test completed!"
puts "="*60

