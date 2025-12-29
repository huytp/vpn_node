require 'sinatra/base'
require 'json'
require 'shellwords'
require 'fileutils'
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
        # Lấy WireGuard keys từ config file hoặc generate
        _wg_private_key, wg_public_key = get_wireguard_keys
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

    def get_wireguard_keys
      # Đọc từ WireGuard config file
      config_path = @config.wg_config_path

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        puts "⚠️  Warning: WG_CONFIG_PATH is set to #{config_path}, but should be /etc/wireguard/wg0.conf"
        puts "   Using /etc/wireguard/wg0.conf instead"
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

      if File.exist?(config_path)
        # Parse config để lấy private key - đọc trực tiếp từ file để tránh shell injection
        config_content = File.read(config_path)

        # Parse chính xác: lấy base64 key, bỏ qua comment và whitespace
        # Format: PrivateKey = <base64_key> hoặc PrivateKey = <base64_key> # comment
        private_key_match = config_content.match(/^PrivateKey\s*=\s*([A-Za-z0-9+\/]+=*)\s*(?:#.*)?$/m)

        # Fallback: parse từng dòng nếu regex không match
        unless private_key_match
          config_content.each_line do |line|
            if line.strip.start_with?('PrivateKey')
              # Extract key từ dòng: PrivateKey = key hoặc PrivateKey=key
              parts = line.split('=', 2)
              if parts.length == 2
                # Lấy phần sau dấu =, loại bỏ comment và whitespace
                key_part = parts[1].split('#').first.strip
                # Chỉ lấy phần base64 (loại bỏ ký tự không hợp lệ)
                key_part = key_part.scan(/[A-Za-z0-9+\/]+=*/).join
                if key_part.length >= 40 && key_part.length <= 50
                  private_key_match = [nil, key_part]
                  break
                end
              end
            end
          end
        end

        if private_key_match
          # Lấy key từ capture group hoặc từ fallback
          private_key = private_key_match[1].strip

          # Thử generate public key để validate key (cách tốt nhất để kiểm tra)
          public_key_result = `printf '%s' "#{private_key}" | wg pubkey 2>&1`.strip

          if $?.success? && !public_key_result.empty? && !public_key_result.include?('error') && !public_key_result.include?('Key is not') && public_key_result.length > 0
            puts "✅ Successfully loaded WireGuard keys from #{config_path}"
            return [private_key, public_key_result]
          else
            puts "⚠️  Failed to generate public key from private key"
            puts "   Error output: #{public_key_result}" unless public_key_result.empty?
            puts "   Private key length: #{private_key.length}"
            puts "   Private key preview: #{private_key[0..10]}..." if private_key.length > 10
          end
        else
          puts "⚠️  PrivateKey not found in existing config file: #{config_path}"
          puts "   Config content preview:"
          puts config_content.lines.first(5).join
        end
      end

      # CHỈ generate key pair mới nếu config file CHƯA TỒN TẠI
      # Điều này đảm bảo keys không thay đổi sau khi được tạo
      unless File.exist?(config_path)
        puts "📝 WireGuard config file not found, generating new keys..."
        private_key, public_key = WireGuard.generate_key_pair
        create_initial_wireguard_config(private_key, skip_reload: true)
        [private_key, public_key]
      else
        # Config file tồn tại nhưng không parse được - báo lỗi, không generate key mới
        puts "⚠️  Config file exists but failed to parse keys. Please check the config file manually."
        raise "Failed to parse WireGuard keys from existing config file"
      end
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

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

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

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        puts "⚠️  Warning: WG_CONFIG_PATH is set to #{config_path}, but should be /etc/wireguard/wg0.conf"
        puts "   Using /etc/wireguard/wg0.conf instead"
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

      config_dir = File.dirname(config_path)

      puts "📝 Creating WireGuard config at: #{config_path}"
      FileUtils.mkdir_p(config_dir)

      # Generate address (10.0.0.x/24)
      node_index = @signer.address[-2..-1].to_i(16) % 254 + 1
      address = "10.0.0.#{node_index}/24"

      # Detect network interface (ens4, eth0, etc.)
      network_interface = ENV['NETWORK_INTERFACE'] || 'ens4'

      config_content = <<~CONFIG
        [Interface]
        PrivateKey = #{private_key}
        Address = #{address}
        ListenPort = #{get_wireguard_listen_port}

        # Enable forwarding + NAT
        PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o #{network_interface} -j MASQUERADE
        PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o #{network_interface} -j MASQUERADE
      CONFIG

      begin
        File.write(config_path, config_content)
        File.chmod(0600, config_path)

        # Verify file was written
        if File.exist?(config_path)
          puts "✅ WireGuard config successfully saved to #{config_path}"
        else
          puts "❌ Error: Config file was not created at #{config_path}"
        end
      rescue Errno::EACCES => e
        puts "❌ Permission denied writing to #{config_path}: #{e.message}"
        puts "   Please run with sudo or ensure write access to #{config_dir}"
        raise
      rescue => e
        puts "❌ Failed to write WireGuard config to #{config_path}: #{e.message}"
        raise
      end

      # Chỉ reload nếu interface đã tồn tại và không skip
      unless skip_reload
        reload_wireguard_config
      end
    end

    def add_wireguard_peer(peer_public_key, allowed_ips, connection_id)
      config_path = @config.wg_config_path

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        puts "⚠️  Warning: WG_CONFIG_PATH is set to #{config_path}, but should be /etc/wireguard/wg0.conf"
        puts "   Using /etc/wireguard/wg0.conf instead"
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

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

      # Đảm bảo config_path luôn là /etc/wireguard/wg0.conf
      unless config_path == '/etc/wireguard/wg0.conf'
        puts "⚠️  Warning: WG_CONFIG_PATH is set to #{config_path}, but should be /etc/wireguard/wg0.conf"
        puts "   Using /etc/wireguard/wg0.conf instead"
        config_path = '/etc/wireguard/wg0.conf'
        @config.wg_config_path = config_path
      end

      return { success: false, error: 'Config file not found' } unless File.exist?(config_path)

      # Đọc config
      lines = File.readlines(config_path)

      # Tìm index của comment chứa connection_id
      comment_index = nil
      lines.each_with_index do |line, index|
        if line.include?("Connection: #{connection_id}")
          comment_index = index
          break
        end
      end

      # Nếu không tìm thấy connection_id, peer không tồn tại
      unless comment_index
        return { success: false, error: "Peer with connection_id #{connection_id} not found" }
      end

      # Quét ngược lại từ comment để tìm [Peer] gần nhất
      peer_start_index = nil
      (comment_index.downto(0)).each do |i|
        if lines[i].strip == '[Peer]'
          peer_start_index = i
          break
        end
      end

      # Nếu không tìm thấy [Peer], có thể format không đúng
      unless peer_start_index
        return { success: false, error: "Could not find [Peer] section for connection_id #{connection_id}" }
      end

      # Tìm index của section tiếp theo (hoặc cuối file)
      peer_end_index = lines.length
      ((peer_start_index + 1)...lines.length).each do |i|
        if lines[i].strip.start_with?('[')
          peer_end_index = i
          break
        end
      end

      # Xóa peer section (từ [Peer] đến trước section tiếp theo)
      new_lines = lines[0...peer_start_index] + lines[peer_end_index..-1]

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
      # Fix cứng interface name là wg0
      interface = 'wg0'
      config_path = '/etc/wireguard/wg0.conf'

      return unless File.exist?(config_path)

      # Kiểm tra xem interface đã up chưa
      interface_exists = `ip link show #{interface} 2>/dev/null`.strip

      if interface_exists.empty?
        # Interface chưa tồn tại, cần up interface
        puts "Interface #{interface} not found, bringing it up..."
        result = system("wg-quick up #{interface} >/dev/null 2>&1")
        unless result
          error_output = `wg-quick up #{interface} 2>&1`
          puts "⚠️  Failed to bring up WireGuard interface: #{error_output.strip}"
          return false
        end
        puts "✅ WireGuard interface #{interface} brought up successfully"
        return true
      else
        # Interface đã tồn tại, reload config bằng cách down và up lại
        # Sử dụng interface name để wg-quick tự động tìm file config
        puts "Reloading WireGuard config for #{interface}..."

        # Đảm bảo file config tồn tại
        unless File.exist?(config_path)
          puts "⚠️  Config file does not exist: #{config_path}"
          return false
        end

        # Backup file config trước khi down (vì wg-quick down có thể xóa file)
        backup_path = "#{config_path}.reload_backup"
        begin
          FileUtils.cp(config_path, backup_path)
          puts "✅ Backed up config to #{backup_path}"
        rescue => e
          puts "⚠️  Failed to backup config: #{e.message}"
        end

        # Down interface
        puts "Bringing down interface #{interface}..."
        down_result = system("wg-quick down #{interface} >/dev/null 2>&1")
        unless down_result
          error_output = `wg-quick down #{interface} 2>&1`
          puts "⚠️  Warning: Failed to bring down interface: #{error_output.strip}"
          # Tiếp tục thử up lại vì có thể interface đã down rồi
        end

        # Đợi một chút để đảm bảo interface đã down hoàn toàn
        sleep(0.5)

        # Kiểm tra file config còn tồn tại không, nếu không thì restore từ backup
        unless File.exist?(config_path)
          puts "⚠️  Config file disappeared after down, restoring from backup..."
          if File.exist?(backup_path)
            FileUtils.cp(backup_path, config_path)
            File.chmod(0600, config_path)
            puts "✅ Restored config from backup"
          else
            puts "❌ Backup file not found, cannot restore config"
            return false
          end
        end

        # Up lại interface với config mới
        puts "Bringing up interface #{interface}..."
        up_result = system("wg-quick up #{interface} >/dev/null 2>&1")
        unless up_result
          error_output = `wg-quick up #{interface} 2>&1`
          puts "⚠️  Failed to reload WireGuard config: #{error_output.strip}"
          puts "   Config path: #{config_path}"
          puts "   File exists: #{File.exist?(config_path)}"

          # Cleanup backup
          FileUtils.rm_f(backup_path) if File.exist?(backup_path)
          return false
        end

        # Cleanup backup file sau khi thành công
        FileUtils.rm_f(backup_path) if File.exist?(backup_path)

        puts "✅ WireGuard config reloaded successfully"
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

