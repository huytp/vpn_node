require 'httparty'
require 'json'
require 'sys/proctable'
require 'open-uri'

module VPNNode
  class HeartbeatSender
    def initialize(signer, backend_url)
      @signer = signer
      @backend_url = backend_url
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
  end
end

