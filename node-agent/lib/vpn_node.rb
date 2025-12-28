# Main module for VPN Node Agent
module VPNNode
  VERSION = '1.0.0'
end

require_relative 'config'
require_relative 'signer'
require_relative 'heartbeat'
require_relative 'traffic_meter'
require_relative 'wireguard'
require_relative 'rpc_client'
require_relative 'reward_claimer'
require_relative 'reward_verifier'
require_relative 'agent'

