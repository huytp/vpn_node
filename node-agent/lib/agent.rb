require_relative 'config'
require_relative 'signer'
require_relative 'heartbeat'
require_relative 'traffic_meter'
require_relative 'traffic_sender'
require_relative 'wireguard'
require_relative 'reward_claimer'
require_relative 'api_server'
require 'thread'

module VPNNode
  class Agent
    def initialize
      @config = Config.new
      @config.validate!

      @signer = Signer.new(@config.private_key_path)

      # Verify node address matches
      unless @signer.address.downcase == @config.node_address.downcase
        raise "Node address mismatch: expected #{@config.node_address}, got #{@signer.address}"
      end

      @traffic_meter = TrafficMeter.new(@signer)
      @traffic_sender = TrafficSender.new(@signer, @config.backend_url, @traffic_meter)
      @heartbeat_sender = HeartbeatSender.new(@signer, @config.backend_url, @config)
      @wg_previous_stats = {} # Lưu stats trước đó để tính delta

      # Initialize reward claimer if blockchain config available
      if ENV['RPC_URL'] && ENV['REWARD_CONTRACT_ADDRESS']
        @reward_claimer = RewardClaimer.new(
          @signer,
          @config.backend_url,
          ENV['RPC_URL'],
          ENV['REWARD_CONTRACT_ADDRESS'],
          ENV['CONTRACT_ABI_PATH'],
          ENV['TATUM_API_KEY']
        )
      else
        @reward_claimer = nil
        puts "⚠️  Reward claimer disabled (missing RPC_URL or REWARD_CONTRACT_ADDRESS)"
      end

      @running = false
      @threads = []
      @api_server = nil
    end

    def run
      puts "Starting VPN Node Agent for address: #{@signer.address}"

      # Khởi tạo WireGuard config nếu chưa có
      initialize_wireguard_config

      @running = true

      # Start API server in a separate thread
      @threads << Thread.new { start_api_server }

      # Start heartbeat thread
      @threads << Thread.new { heartbeat_loop }

      # Start traffic reporting thread
      @threads << Thread.new { traffic_report_loop }

      # Start reward claiming thread (if enabled)
      puts "Reward claimer: #{@reward_claimer}"
      if @reward_claimer
        @threads << Thread.new { reward_claim_loop }
      end

      # Handle signals
      Signal.trap('INT') { stop }
      Signal.trap('TERM') { stop }

      # Wait for threads
      @threads.each(&:join)

      puts "Node agent stopped"
    end

    private

    def initialize_wireguard_config
      # Đảm bảo WireGuard config file được tạo khi agent khởi động
      config_path = @config.wg_config_path

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        puts "⚠️  Warning: WG_CONFIG_PATH is set to #{config_path}, but should be /etc/wireguard/wg0.conf"
        puts "   Using /etc/wireguard/wg0.conf instead"
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

      unless File.exist?(config_path)
        puts "📝 WireGuard config file not found, creating initial config..."
        begin
          require_relative 'wireguard'

          # Generate key pair
          private_key, public_key = WireGuard.generate_key_pair

          # Tạo config file
          config_dir = File.dirname(config_path)
          FileUtils.mkdir_p(config_dir)

          # Generate address (10.0.0.x/24)
          node_index = @signer.address[-2..-1].to_i(16) % 254 + 1
          address = "10.0.0.#{node_index}/24"
          listen_port = ENV['WG_LISTEN_PORT'] || 51820

          # Detect network interface (ens4, eth0, etc.)
          network_interface = ENV['NETWORK_INTERFACE'] || 'ens4'

          config_content = <<~CONFIG
            [Interface]
            PrivateKey = #{private_key}
            Address = #{address}
            ListenPort = #{listen_port}

            # Enable forwarding + NAT
            PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o #{network_interface} -j MASQUERADE
            PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o #{network_interface} -j MASQUERADE
          CONFIG

          File.write(config_path, config_content)
          File.chmod(0600, config_path)

          # Verify file was written
          if File.exist?(config_path)
            puts "✅ WireGuard config successfully created at #{config_path}"
            puts "   Public Key: #{public_key}"
          else
            puts "❌ Error: Config file was not created at #{config_path}"
          end
        rescue Errno::EACCES => e
          puts "❌ Permission denied creating WireGuard config: #{e.message}"
          puts "   Please run with sudo or ensure write access to #{File.dirname(config_path)}"
          puts "   Or create the config file manually at: #{config_path}"
          raise
        rescue => e
          puts "❌ Failed to create WireGuard config: #{e.message}"
          puts "   You may need to create it manually at: #{config_path}"
          raise
        end
      else
        puts "✅ WireGuard config file exists at #{config_path}"
      end
    end

    def start_api_server
      require 'rack'
      require 'rack/handler/webrick'

      @api_server = ApiServer.new(self)
      port = ENV['NODE_API_PORT'] || 51820
      puts "Starting API server on port #{port}"

      Rack::Handler::WEBrick.run(@api_server, Port: port.to_i, Host: '0.0.0.0')
    rescue => e
      puts "API server error: #{e.message}"
      puts e.backtrace.first(5)
    end

    def heartbeat_loop
      # Send initial heartbeat
      @heartbeat_sender.send

      loop do
        break unless @running

        sleep @config.heartbeat_interval

        if @running
          if @heartbeat_sender.send
            puts "Heartbeat sent successfully"
          end
        end
      end
    rescue => e
      puts "Heartbeat loop error: #{e.message}"
      puts e.backtrace
    end

    def traffic_report_loop
      puts "Traffic report loop started"

      loop do
        break unless @running

        sleep 10

        if @running
          begin
            # Sync WireGuard peers với TrafficMeter sessions
            sync_wireguard_sessions

            # Lấy tất cả active sessions
            active_sessions = @traffic_meter.get_active_sessions

            if active_sessions.any?
              total_traffic = @traffic_meter.get_total_traffic
              puts "📊 Total traffic: %.2f MB (#{active_sessions.length} active session(s))" % total_traffic

              # Lấy current epoch_id từ backend
              current_epoch_id = @traffic_sender.get_current_epoch_id

              # Gửi batch để hiệu quả hơn
              @traffic_sender.send_traffic_records_batch(active_sessions, current_epoch_id)
            else
              puts "📊 No active sessions"
            end
          rescue => e
            puts "Traffic report loop error: #{e.message}"
            puts e.backtrace.first(3)
          end
        end
      end
    rescue => e
      puts "Traffic report loop error: #{e.message}"
      puts e.backtrace
    end

    # Đồng bộ VPN connections từ backend với TrafficMeter sessions
    def sync_wireguard_sessions
      begin
        # Lấy active VPN connections từ backend (connections mà node này là entry hoặc exit)
        active_connections = get_active_connections_from_backend

        # Lấy stats từ WireGuard interface
        wg_stats = WireGuard.get_stats(@config.wg_interface)

        # Lấy active sessions hiện tại
        current_sessions = @traffic_meter.get_active_sessions

        # Tạo sessions mới cho các connections mới
        active_connections.each do |connection|
          connection_id = connection['connection_id']

          unless current_sessions.include?(connection_id)
            @traffic_meter.start_session(connection_id)
            puts "➕ Started tracking session: #{connection_id} (user: #{connection['user_address']})"
          end

          # Cập nhật traffic từ WireGuard nếu có
          if wg_stats.any?
            # Tính tổng traffic từ tất cả peers (vì có thể có nhiều peers cho một connection)
            total_bytes_in = 0
            total_bytes_out = 0

            wg_stats.each do |peer_public_key, stats|
              # Lấy previous stats để tính delta
              prev_stats = @wg_previous_stats[peer_public_key] || { bytes_received: 0, bytes_sent: 0 }

              bytes_received = stats[:bytes_received] || 0
              bytes_sent = stats[:bytes_sent] || 0

              # Tính delta (chênh lệch so với lần trước)
              delta_bytes_in = [bytes_received - prev_stats[:bytes_received], 0].max
              delta_bytes_out = [bytes_sent - prev_stats[:bytes_sent], 0].max

              # Lưu stats hiện tại cho lần sau
              @wg_previous_stats[peer_public_key] = {
                bytes_received: bytes_received,
                bytes_sent: bytes_sent
              }

              total_bytes_in += delta_bytes_in
              total_bytes_out += delta_bytes_out
            end

            # Cập nhật traffic cho session (chia đều cho tất cả connections)
            if total_bytes_in > 0 || total_bytes_out > 0
              bytes_per_connection = total_bytes_in / active_connections.length
              bytes_out_per_connection = total_bytes_out / active_connections.length
              @traffic_meter.update_session(connection_id, bytes_per_connection, bytes_out_per_connection)
            end
          end
        end

        # Xóa sessions không còn trong backend connections
        current_sessions.each do |session_id|
          found = active_connections.any? { |conn| conn['connection_id'] == session_id }

          unless found
            # Gửi traffic record trước khi xóa
            begin
              current_epoch_id = @traffic_sender.get_current_epoch_id
              @traffic_sender.send_on_session_end(session_id, current_epoch_id)
            rescue => e
              puts "⚠️  Failed to send traffic record for ended session #{session_id}: #{e.message}"
            end

            @traffic_meter.end_session(session_id)
            puts "➖ Ended tracking session: #{session_id}"
          end
        end
      rescue => e
        puts "⚠️  Failed to sync WireGuard sessions: #{e.message}"
        puts e.backtrace.first(3)
        # Không raise để loop vẫn tiếp tục chạy
      end
    end

    # Lấy active VPN connections từ backend mà node này tham gia
    def get_active_connections_from_backend
      begin
        require 'httparty'

        response = HTTParty.get(
          "#{@config.backend_url}/vpn/connections/active",
          query: { node: @signer.address },
          headers: { 'Content-Type' => 'application/json' },
          timeout: 5
        )

        if response.success?
          data = JSON.parse(response.body)
          return data['connections'] || []
        else
          puts "⚠️  Failed to get active connections: #{response.code} - #{response.body}"
          return []
        end
      rescue => e
        puts "⚠️  Error getting active connections: #{e.message}"
        return []
      end
    end

    def reward_claim_loop
      return unless @reward_claimer

      # Wait a bit before first check
      sleep 60
      puts "Reward claim loop started"

      loop do
        break unless @running

        # Check for available rewards every 5 minutes
        sleep 120

        if @running
          begin
            puts "Checking for pending rewards"
            pending_rewards = @reward_claimer.get_pending_rewards
            puts "Pending rewards: #{pending_rewards}"
            if pending_rewards.any?
              puts "💰 Found #{pending_rewards.length} pending reward(s)"

              pending_rewards.each do |reward|
                puts "  - Epoch #{reward[:epoch]}: #{reward[:amount]} DEVPN"
                @reward_claimer.claim_reward(reward[:epoch])
                sleep 10 # Wait between claims
              end
            end
          rescue => e
            puts "Reward claim loop error: #{e.message}"
            puts e.backtrace.first(3)
          end
        end
      end
    rescue => e
      puts "Reward claim loop error: #{e.message}"
      puts e.backtrace
    end

    def stop
      puts "\nShutting down node agent..."
      @running = false

      # Give threads time to finish
      sleep 2

      @threads.each(&:kill)
    end
  end
end

