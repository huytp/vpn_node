require 'sinatra/base'
require 'json'
require_relative 'wireguard'

module VPNNode
  class ApiServer < Sinatra::Base
    set :port, ENV['NODE_API_PORT'] || 51820
    set :bind, '0.0.0.0'

    def initialize(agent)
      super()
      @agent = agent
      @config = agent.instance_variable_get(:@config)
      @signer = agent.instance_variable_get(:@signer)
    end

    # GET /api/info - Lấy thông tin node (public key, endpoint)
    get '/api/info' do
      content_type :json

      begin
        # Lấy WireGuard public key từ config file hoặc generate
        wg_public_key = get_wireguard_public_key
        wg_listen_port = get_wireguard_listen_port
        wg_endpoint = get_wireguard_endpoint

        {
          node_address: @signer.address,
          wireguard: {
            public_key: wg_public_key,
            listen_port: wg_listen_port,
            endpoint: wg_endpoint
          }
        }.to_json
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    # POST /api/peers - Thêm peer vào WireGuard config
    post '/api/peers' do
      content_type :json

      begin
        request_data = JSON.parse(request.body.read)
        peer_public_key = request_data['public_key']
        allowed_ips = request_data['allowed_ips'] || '0.0.0.0/0'
        connection_id = request_data['connection_id']

        unless peer_public_key
          status 400
          return { error: 'public_key is required' }.to_json
        end

        # Thêm peer vào WireGuard config
        result = add_wireguard_peer(peer_public_key, allowed_ips, connection_id)

        if result[:success]
          { success: true, message: 'Peer added successfully' }.to_json
        else
          status 500
          { error: result[:error] }.to_json
        end
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    # DELETE /api/peers/:connection_id - Xóa peer khỏi WireGuard config
    delete '/api/peers/:connection_id' do
      content_type :json

      begin
        connection_id = params[:connection_id]

        result = remove_wireguard_peer(connection_id)

        if result[:success]
          { success: true, message: 'Peer removed successfully' }.to_json
        else
          status 500
          { error: result[:error] }.to_json
        end
      rescue => e
        status 500
        { error: e.message }.to_json
      end
    end

    # GET /api/health - Health check
    get '/api/health' do
      content_type :json
      { status: 'ok', node_address: @signer.address }.to_json
    end

    private

    def get_wireguard_public_key
      # Đọc từ WireGuard config file
      config_path = @config.wg_config_path

      if File.exist?(config_path)
        # Parse config để lấy public key (cần private key để derive public key)
        private_key = `grep "^PrivateKey" #{config_path} | cut -d'=' -f2 | tr -d ' '`.strip

        unless private_key.empty?
          return `echo "#{private_key}" | wg pubkey`.strip
        end
      end

      # Nếu không có config, generate key pair mới
      private_key, public_key = WireGuard.generate_key_pair

      # Tạo config file nếu chưa có
      unless File.exist?(config_path)
        create_initial_wireguard_config(private_key)
      end

      public_key
    end

    def get_wireguard_listen_port
      config_path = @config.wg_config_path

      if File.exist?(config_path)
        port = `grep "^ListenPort" #{config_path} | cut -d'=' -f2 | tr -d ' '`.strip
        return port.to_i unless port.empty?
      end

      # Default port
      51820
    end

    def get_wireguard_endpoint
      # Lấy public IP của node (có thể từ env hoặc detect)
      public_ip = ENV['NODE_PUBLIC_IP'] || detect_public_ip
      listen_port = get_wireguard_listen_port

      "#{public_ip}:#{listen_port}"
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

      # Fallback: lấy từ interface
      `hostname -I | awk '{print $1}'`.strip
    end

    def create_initial_wireguard_config(private_key)
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
        ListenPort = #{get_wireguard_listen_port}
      CONFIG

      File.write(config_path, config_content, mode: '0600')
    end

    def add_wireguard_peer(peer_public_key, allowed_ips, connection_id)
      config_path = @config.wg_config_path

      # Đọc config hiện tại
      config_content = File.exist?(config_path) ? File.read(config_path) : ''

      # Kiểm tra peer đã tồn tại chưa
      if config_content.include?(peer_public_key)
        return { success: true, message: 'Peer already exists' }
      end

      # Thêm peer vào config
      peer_section = <<~PEER
        [Peer]
        # Connection: #{connection_id}
        PublicKey = #{peer_public_key}
        AllowedIPs = #{allowed_ips}
      PEER

      new_config = config_content + "\n" + peer_section

      # Backup config trước khi ghi
      FileUtils.cp(config_path, "#{config_path}.backup") if File.exist?(config_path)

      # Ghi config mới
      File.write(config_path, new_config, mode: '0600')

      # Reload WireGuard config
      reload_wireguard_config

      { success: true }
    rescue => e
      { success: false, error: e.message }
    end

    def remove_wireguard_peer(connection_id)
      config_path = @config.wg_config_path

      return { success: false, error: 'Config file not found' } unless File.exist?(config_path)

      # Đọc config
      lines = File.readlines(config_path)
      new_lines = []
      skip_peer = false
      skip_until_next_section = false

      lines.each do |line|
        # Tìm comment với connection_id
        if line.include?("Connection: #{connection_id}")
          skip_peer = true
          skip_until_next_section = true
          next
        end

        # Nếu đang skip peer section
        if skip_until_next_section
          # Bỏ qua các dòng cho đến khi gặp section mới ([Peer] hoặc [Interface])
          if line.strip.start_with?('[')
            skip_until_next_section = false
            # Không thêm dòng [Peer] của peer bị xóa
            next if line.strip == '[Peer]'
            new_lines << line
          end
          next
        end

        new_lines << line
      end

      # Backup và ghi config mới
      FileUtils.cp(config_path, "#{config_path}.backup") if File.exist?(config_path)
      File.write(config_path, new_lines.join, mode: '0600')

      # Reload WireGuard config
      reload_wireguard_config

      { success: true }
    rescue => e
      { success: false, error: e.message }
    end

    def reload_wireguard_config
      # Reload WireGuard config
      interface = @config.wg_interface
      config_path = @config.wg_config_path

      # Sử dụng wg syncconf để reload config không cần down/up interface
      stripped_config = `wg-quick strip #{config_path} 2>/dev/null`.strip
      unless stripped_config.empty?
        IO.popen("wg syncconf #{interface} -", 'w') do |io|
          io.write(stripped_config)
          io.close_write
        end
      end
    rescue => e
      Rails.logger.error("Failed to reload WireGuard config: #{e.message}") if defined?(Rails)
      puts "Failed to reload WireGuard config: #{e.message}"
    end
  end
end

