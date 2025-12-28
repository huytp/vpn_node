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

    # GET /api/info - Lấy thông tin node (public key, private key, endpoint)
    get '/api/info' do
      content_type :json

      begin
        # Lấy WireGuard keys từ config file hoặc generate
        wg_private_key, wg_public_key = get_wireguard_keys
        wg_listen_port = get_wireguard_listen_port
        wg_endpoint = get_wireguard_endpoint

        {
          node_address: @signer.address,
          wireguard: {
            private_key: wg_private_key,
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

    def get_wireguard_keys
      # Đọc từ WireGuard config file
      config_path = @config.wg_config_path

      if File.exist?(config_path)
        # Parse config để lấy private key - đọc trực tiếp từ file để tránh shell injection
        config_content = File.read(config_path)
        private_key_match = config_content.match(/^PrivateKey\s*=\s*(.+)$/m)

        if private_key_match
          # Loại bỏ tất cả whitespace, newline, và carriage return
          private_key = private_key_match[1].gsub(/[\s\n\r]/, '').strip

          # Validate key format (base64, ~44 characters)
          if private_key.length >= 40 && private_key.length <= 50 && private_key.match?(/^[A-Za-z0-9+\/]+=*$/)
            # Generate public key từ private key - sử dụng printf để tránh shell interpretation
            public_key_result = `printf '%s' "#{private_key}" | wg pubkey 2>&1`.strip

            if $?.success? && !public_key_result.empty? && !public_key_result.include?('error') && !public_key_result.include?('Key is not')
              return [private_key, public_key_result]
            else
              puts "⚠️  Failed to generate public key from private key: #{public_key_result}"
            end
          else
            puts "⚠️  Invalid private key format in config file (length: #{private_key.length}, format: #{private_key.match?(/^[A-Za-z0-9+\/]+=*$/).inspect})"
          end
        end
      end

      # Nếu không có config, generate key pair mới
      private_key, public_key = WireGuard.generate_key_pair

      # Tạo config file nếu chưa có (không reload ngay, sẽ reload khi cần)
      unless File.exist?(config_path)
        create_initial_wireguard_config(private_key, skip_reload: true)
      end

      [private_key, public_key]
    end

    def get_wireguard_public_key
      # Wrapper để tương thích với code cũ
      _, public_key = get_wireguard_keys
      public_key
    end

    def get_wireguard_private_key
      # Lấy private key
      private_key, _ = get_wireguard_keys
      private_key
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

    def create_initial_wireguard_config(private_key, skip_reload: false)
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

      File.write(config_path, config_content)
      File.chmod(0600, config_path)

      # Chỉ reload nếu interface đã tồn tại và không skip
      unless skip_reload
        reload_wireguard_config
      end
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
      File.write(config_path, new_config)
      File.chmod(0600, config_path)

      # Reload WireGuard config (chỉ khi interface đã up)
      begin
        reload_wireguard_config
      rescue => e
        puts "⚠️  Warning: Failed to reload WireGuard config: #{e.message}"
        # Không fail toàn bộ operation nếu chỉ reload thất bại
      end

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
      File.write(config_path, new_lines.join)
      File.chmod(0600, config_path)

      # Reload WireGuard config (chỉ khi interface đã up)
      begin
        reload_wireguard_config
      rescue => e
        puts "⚠️  Warning: Failed to reload WireGuard config: #{e.message}"
        # Không fail toàn bộ operation nếu chỉ reload thất bại
      end

      { success: true }
    rescue => e
      { success: false, error: e.message }
    end

    def reload_wireguard_config
      # Reload WireGuard config
      interface = @config.wg_interface
      config_path = @config.wg_config_path

      return unless File.exist?(config_path)

      # Kiểm tra xem interface đã up chưa
      interface_exists = `ip link show #{interface} 2>/dev/null`.strip

      if interface_exists.empty?
        # Interface chưa tồn tại, cần up interface
        puts "Interface #{interface} not found, bringing it up..."
        result = system("wg-quick up #{config_path} >/dev/null 2>&1")
        unless result
          error_output = `wg-quick up #{config_path} 2>&1`
          puts "⚠️  Failed to bring up WireGuard interface: #{error_output.strip}"
          return false
        end
        return true
      else
        # Interface đã tồn tại, chỉ reload config
        # Validate config trước khi reload bằng cách strip
        stripped_output = `wg-quick strip #{config_path} 2>&1`

        unless $?.success?
          puts "⚠️  WireGuard config validation failed: #{stripped_output.strip}"
          puts "   Config file may have invalid keys or format"
          return false
        end

        if stripped_output.strip.empty?
          puts "⚠️  WireGuard config is empty after stripping"
          return false
        end

        # Config hợp lệ, reload
        reload_result = IO.popen("wg syncconf #{interface} - 2>&1", 'w') do |io|
          io.write(stripped_output)
          io.close_write
        end

        unless $?.success?
          error_output = `wg syncconf #{interface} - 2>&1 < /dev/null`
          puts "⚠️  Failed to reload WireGuard config: #{error_output.strip}"
          return false
        end

        return true
      end
    rescue => e
      Rails.logger.error("Failed to reload WireGuard config: #{e.message}") if defined?(Rails)
      puts "⚠️  Failed to reload WireGuard config: #{e.message}"
      puts e.backtrace.first(3) if defined?(Rails)
      false
    end
  end
end

