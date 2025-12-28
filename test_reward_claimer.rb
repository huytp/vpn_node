#!/usr/bin/env ruby

require_relative 'node-agent/lib/vpn_node'
require 'webmock'
require 'json'

# Mock HTTP responses for testing
include WebMock::API

# Test configuration
TEST_PRIVATE_KEY_PATH = './keys/node.key'
TEST_BACKEND_URL = 'http://localhost:3000'
TEST_RPC_URL = 'https://polygon-mumbai.g.alchemy.com/v2/test'
TEST_CONTRACT_ADDRESS = '0x1234567890123456789012345678901234567890'

# Colors for output
class String
  def green; "\033[32m#{self}\033[0m" end
  def red; "\033[31m#{self}\033[0m" end
  def yellow; "\033[33m#{self}\033[0m" end
  def blue; "\033[34m#{self}\033[0m" end
end

def print_test(name)
  puts "\n#{'='*60}".blue
  puts "TEST: #{name}".blue
  puts '='*60
end

def print_success(message)
  puts "✅ #{message}".green
end

def print_error(message)
  puts "❌ #{message}".red
end

def print_info(message)
  puts "ℹ️  #{message}".yellow
end

# Setup: Create signer
print_test("Setup")
begin
  unless File.exist?(TEST_PRIVATE_KEY_PATH)
    print_info("Creating test private key...")
    VPNNode::Signer.generate_key(TEST_PRIVATE_KEY_PATH)
  end

  signer = VPNNode::Signer.new(TEST_PRIVATE_KEY_PATH)
  print_success("Signer initialized")
  print_info("Node address: #{signer.address}")
  print_info("Private key loaded from: #{TEST_PRIVATE_KEY_PATH}")
rescue => e
  print_error("Failed to setup signer: #{e.message}")
  exit 1
end

# Test 1: Initialize RewardClaimer
print_test("Test 1: Initialize RewardClaimer")
begin
  claimer = VPNNode::RewardClaimer.new(
    signer,
    TEST_BACKEND_URL,
    TEST_RPC_URL,
    TEST_CONTRACT_ADDRESS
  )
  print_success("RewardClaimer initialized successfully")
rescue => e
  print_error("Failed to initialize: #{e.message}")
  puts e.backtrace.first(5)
  exit 1
end

# Test 2: Fetch proof (with mock)
print_test("Test 2: Fetch proof from backend")
begin
  # Mock successful response
  mock_proof_data = {
    'epoch' => 1,
    'node' => signer.address,
    'amount' => '1000000000000000000', # 1 DEVPN in wei
    'proof' => [
      '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
      '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890'
    ]
  }

  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/proof")
    .with(query: { node: signer.address, epoch: 1 })
    .to_return(
      status: 200,
      body: mock_proof_data.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

  proof_data = claimer.fetch_proof(1)

  if proof_data && proof_data['epoch'] == 1
    print_success("Proof fetched successfully")
    print_info("Epoch: #{proof_data['epoch']}")
    print_info("Amount: #{proof_data['amount']}")
    print_info("Proof length: #{proof_data['proof'].length}")
  else
    print_error("Failed to fetch proof or invalid data")
  end
rescue => e
  print_error("Error in fetch_proof test: #{e.message}")
  puts e.backtrace.first(5)
end

# Test 3: Verify proof data
print_test("Test 3: Verify proof data")
begin
  valid_proof = {
    'epoch' => 1,
    'node' => signer.address,
    'amount' => '1000000000000000000',
    'proof' => ['0x1234', '0x5678']
  }

  invalid_proof = {
    'epoch' => 1,
    'node' => '0xDifferentAddress',
    'amount' => '0',
    'proof' => []
  }

  # Test valid proof (using send to access private method)
  result = claimer.send(:verify_proof_data, valid_proof)
  if result
    print_success("Valid proof data verified")
  else
    print_error("Valid proof should pass verification")
  end

  # Test invalid proof
  result = claimer.send(:verify_proof_data, invalid_proof)
  if !result
    print_success("Invalid proof data correctly rejected")
  else
    print_error("Invalid proof should fail verification")
  end
rescue => e
  print_error("Error in verify_proof_data test: #{e.message}")
  puts e.backtrace.first(5)
end

# Test 4: Check available rewards
print_test("Test 4: Check available rewards")
begin
  mock_epochs = [
    { 'epoch_id' => 1, 'status' => 'committed', 'start_time' => '2024-01-01', 'end_time' => '2024-01-02' },
    { 'epoch_id' => 2, 'status' => 'pending', 'start_time' => '2024-01-02', 'end_time' => '2024-01-03' },
    { 'epoch_id' => 3, 'status' => 'committed', 'start_time' => '2024-01-03', 'end_time' => '2024-01-04' }
  ]

  stub_request(:get, "#{TEST_BACKEND_URL}/epochs")
    .to_return(
      status: 200,
      body: mock_epochs.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

  available = claimer.check_available_rewards
  committed_count = available.count { |e| e['status'] == 'committed' }

  if committed_count == 2
    print_success("Available rewards checked successfully")
    print_info("Found #{committed_count} committed epochs")
  else
    print_error("Expected 2 committed epochs, got #{committed_count}")
  end
rescue => e
  print_error("Error in check_available_rewards test: #{e.message}")
  puts e.backtrace.first(5)
end

# Test 5: Get pending rewards
print_test("Test 5: Get pending rewards")
begin
  # Setup mocks for get_pending_rewards
  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/epochs")
    .to_return(
      status: 200,
      body: [
        { 'epoch_id' => 1, 'status' => 'committed', 'start_time' => '2024-01-01', 'end_time' => '2024-01-02' }
      ].to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/proof")
    .with(query: { node: signer.address, epoch: 1 })
    .to_return(
      status: 200,
      body: {
        'epoch' => 1,
        'node' => signer.address,
        'amount' => '500000000000000000',
        'proof' => ['0x1234']
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

  pending = claimer.get_pending_rewards

  if pending.is_a?(Array)
    print_success("Pending rewards retrieved")
    print_info("Found #{pending.length} pending reward(s)")
    pending.each do |reward|
      print_info("  - Epoch #{reward[:epoch]}: #{reward[:amount]} DEVPN")
    end
  else
    print_error("Expected array, got #{pending.class}")
  end
rescue => e
  print_error("Error in get_pending_rewards test: #{e.message}")
  puts e.backtrace.first(5)
end

# Test 6: Claim reward (mock)
print_test("Test 6: Claim reward")
begin
  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/proof")
    .with(query: { node: signer.address, epoch: 1 })
    .to_return(
      status: 200,
      body: {
        'epoch' => 1,
        'node' => signer.address,
        'amount' => '1000000000000000000',
        'proof' => [
          '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
          '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890'
        ]
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

  result = claimer.claim_reward(1)

  if result
    print_success("Reward claim process completed")
    print_info("Note: Contract interaction is not fully implemented yet")
  else
    print_error("Reward claim failed")
  end
rescue => e
  print_error("Error in claim_reward test: #{e.message}")
  puts e.backtrace.first(5)
end

# Test 7: Error handling
print_test("Test 7: Error handling")
begin
  # Test fetch_proof with error response
  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/proof")
    .with(query: { node: signer.address, epoch: 999 })
    .to_return(status: 404, body: 'Not found')

  result = claimer.fetch_proof(999)
  if result.nil?
    print_success("Error handling works correctly (returns nil on error)")
  else
    print_error("Should return nil on error")
  end

  # Test with network error
  stub_request(:get, "#{TEST_BACKEND_URL}/rewards/proof")
    .with(query: { node: signer.address, epoch: 888 })
    .to_raise(StandardError.new("Network error"))

  result = claimer.fetch_proof(888)
  if result.nil?
    print_success("Network error handled correctly")
  else
    print_error("Should handle network errors")
  end
rescue => e
  print_error("Error in error handling test: #{e.message}")
end

# Summary
puts "\n#{'='*60}".blue
puts "TEST SUMMARY".blue
puts '='*60
puts "All tests completed!".green
puts "\nNote: Some functionality (contract interaction) is not fully implemented yet."
puts "This is expected behavior as noted in the code comments."

