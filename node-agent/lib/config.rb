require 'dotenv/load'

module VPNNode
  class Config
    attr_accessor :node_address, :private_key_path, :backend_url,
                  :heartbeat_interval, :traffic_report_interval,
                  :reward_claim_interval, :wg_interface, :wg_config_path

    def initialize
      @node_address = ENV['NODE_ADDRESS'] || ''
      @private_key_path = ENV['PRIVATE_KEY_PATH'] || './keys/node.key'
      @backend_url = ENV['BACKEND_URL'] || 'http://localhost:3000'
      @heartbeat_interval = (ENV['HEARTBEAT_INTERVAL'] || '30').to_i
      @traffic_report_interval = (ENV['TRAFFIC_REPORT_INTERVAL'] || '60').to_i
      @reward_claim_interval = (ENV['REWARD_CLAIM_INTERVAL'] || '300').to_i # Default 5 minutes
      @wg_interface = ENV['WG_INTERFACE'] || 'wg0'
      @wg_config_path = ENV['WG_CONFIG_PATH'] || '/etc/wireguard/wg0.conf'
    end

    def validate!
      raise 'NODE_ADDRESS is required' if @node_address.empty?
      raise 'Private key file not found' unless File.exist?(@private_key_path)
    end
  end
end

