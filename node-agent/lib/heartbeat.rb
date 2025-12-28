require 'httparty'
require 'json'
require 'sys/proctable'
require 'open-uri'
require 'fileutils'
require_relative 'wireguard'

module VPNNode
  class HeartbeatSender
    def initialize(signer, backend_url, config = nil)
      @signer = signer
      @backend_url = backend_url
      @config = config
      @start_time = Time.now
    end

    def send
      metrics = collect_metrics
      payload = build_payload(metrics)
      signature = @signer.sign_json(payload)
      payload[:signature] = signature

      response = HTTParty.post(
        "#{@backend_url}/nodes/heartbeat",
        body: payload.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      unless response.success?
        raise "Heartbeat failed: #{response.code} - #{response.body}"
      end

      true
    rescue => e
      puts "Failed to send heartbeat: #{e.message}"
      false
    end

    private

    def build_payload(metrics)
      payload = {
        node: @signer.address,
        latency: metrics[:latency],
        loss: metrics[:loss],
        bandwidth: metrics[:bandwidth],
        uptime: (Time.now - @start_time).to_i
      }

      # Thêm node_api_url nếu có
      node_api_port = ENV['NODE_API_PORT'] || '51820'
      node_public_ip = ENV['NODE_PUBLIC_IP'] || detect_public_ip
      if node_public_ip
        payload[:node_api_url] = "http://#{node_public_ip}:#{node_api_port}"
      end

      # Thêm WireGuard keys nếu có config
      if @config
        wg_keys = get_wireguard_keys
        if wg_keys
          payload[:wireguard] = {
            private_key: wg_keys[:private_key],
            public_key: wg_keys[:public_key],
            listen_port: wg_keys[:listen_port],
            endpoint: wg_keys[:endpoint]
          }
        end
      end

      payload
    end

    def detect_public_ip
      # Thử các service để lấy public IP
      services = [
        'https://api.ipify.org',
        'https://ifconfig.me',
        'https://icanhazip.com'
      ]

      services.each do |service|
        begin
          require 'open-uri'
          ip = URI.open(service, read_timeout: 2).read.strip
          return ip if ip.match?(/^\d+\.\d+\.\d+\.\d+$/)
        rescue
          next
        end
      end

      nil
    end

    def collect_metrics
      latency = measure_latency
      bandwidth = get_bandwidth
      loss = 0.0 # TODO: Implement packet loss measurement

      {
        latency: latency,
        loss: loss,
        bandwidth: bandwidth
      }
    end

    def measure_latency
      start = Time.now
      begin
        response = HTTParty.get("#{@backend_url}/health", timeout: 5)
        (Time.now - start) * 1000 # Convert to milliseconds
      rescue
        100.0 # Default latency if failed
      end
    end

    def get_bandwidth
      begin
        # Get network stats using sys-proctable
        stats = Sys::ProcTable.ps.select { |p| p.comm == 'wg' }
        # Simplified - in real implementation, track previous stats
        # For now, return a default value
        0.0
      rescue
        0.0
      end
    end

    def get_wireguard_keys
      return nil unless @config

      config_path = @config.wg_config_path

      # Đọc từ WireGuard config file
      if File.exist?(config_path)
        # Parse config để lấy private key - đọc trực tiếp từ file
        config_content = File.read(config_path)
        private_key_match = config_content.match(/^PrivateKey\s*=\s*(.+)$/m)

        if private_key_match
          # Loại bỏ tất cả whitespace, newline, và carriage return
          private_key = private_key_match[1].gsub(/[\s\n\r]/, '').strip

          # Validate và generate public key
          if private_key.length >= 40 && private_key.length <= 50 && private_key.match?(/^[A-Za-z0-9+\/]+=*$/)
            public_key_result = `printf '%s' "#{private_key}" | wg pubkey 2>&1`.strip

            if $?.success? && !public_key_result.empty? && !public_key_result.include?('error') && !public_key_result.include?('Key is not')
              listen_port = get_wireguard_listen_port
              endpoint = get_wireguard_endpoint(listen_port)

              return {
                private_key: private_key,
                public_key: public_key_result,
                listen_port: listen_port,
                endpoint: endpoint
              }
            end
          end
        end
      end

      # Nếu không có config, generate key pair mới
      private_key, public_key = WireGuard.generate_key_pair
      listen_port = get_wireguard_listen_port
      endpoint = get_wireguard_endpoint(listen_port)

      # Tạo config file nếu chưa có
      unless File.exist?(config_path)
        create_initial_wireguard_config(private_key, listen_port)
      end

      {
        private_key: private_key,
        public_key: public_key,
        listen_port: listen_port,
        endpoint: endpoint
      }
    rescue => e
      puts "⚠️  Failed to get WireGuard keys: #{e.message}"
      nil
    end

    def get_wireguard_listen_port
      return 51820 unless @config

      config_path = @config.wg_config_path

      if File.exist?(config_path)
        port = `grep "^ListenPort" #{config_path} | cut -d'=' -f2 | tr -d ' '`.strip
        return port.to_i unless port.empty?
      end

      51820
    end

    def get_wireguard_endpoint(listen_port)
      public_ip = ENV['NODE_PUBLIC_IP'] || detect_public_ip
      "#{public_ip}:#{listen_port}"
    end

    def create_initial_wireguard_config(private_key, listen_port)
      return unless @config

      config_path = @config.wg_config_path
      config_dir = File.dirname(config_path)

      FileUtils.mkdir_p(config_dir)

      # Generate address (10.0.0.x/24)
      node_index = @signer.address[-2..-1].to_i(16) % 254 + 1
      address = "10.0.0.#{node_index}/24"

      config_content = <<~CONFIG
        [Interface]
        PrivateKey = #{private_key}
        Address = #{address}
        ListenPort = #{listen_port}
      CONFIG

      File.write(config_path, config_content)
      File.chmod(0600, config_path)
    end
  end
end

