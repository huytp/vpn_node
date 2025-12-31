require 'json'
require 'thread'
require 'time'

module VPNNode
  class UrlTracker
    def initialize
      @urls = [] # Array of { url: string, timestamp: Time, connection_id: string }
      @mutex = Mutex.new
      @max_urls = 1000 # Keep last 1000 URLs
      @dns_monitor_thread = nil
      @running = false
    end

    def start_monitoring(interface = 'wg0')
      return if @running

      @running = true
      @dns_monitor_thread = Thread.new do
        monitor_dns_queries(interface)
      end

      puts "[UrlTracker] Started monitoring DNS queries on interface #{interface}"
    end

    def stop_monitoring
      @running = false
      @dns_monitor_thread&.kill
      @dns_monitor_thread = nil
      puts "[UrlTracker] Stopped monitoring"
    end

    def add_url(url, connection_id = nil)
      return unless url && !url.empty?

      # Normalize URL
      normalized_url = normalize_url(url)

      @mutex.synchronize do
        # Remove old URLs if we exceed max
        if @urls.length >= @max_urls
          @urls.shift(@urls.length - @max_urls + 1)
        end

        # Add new URL
        @urls << {
          url: normalized_url,
          timestamp: Time.now,
          connection_id: connection_id
        }
      end
    end

    def get_recent_urls(connection_id = nil, since: nil, limit: 100)
      @mutex.synchronize do
        urls = @urls.dup

        # Filter by connection_id if provided
        if connection_id
          urls = urls.select { |u| u[:connection_id] == connection_id }
        end

        # Filter by timestamp if provided
        if since
          urls = urls.select { |u| u[:timestamp] >= since }
        end

        # Sort by timestamp (newest first) and limit
        urls.sort_by { |u| -u[:timestamp].to_i }.first(limit)
      end
    end

    def get_unique_domains(connection_id = nil, since: nil)
      urls = get_recent_urls(connection_id, since: since, limit: 1000)
      domains = urls.map { |u| extract_domain(u[:url]) }.compact.uniq
      domains
    end

    private

    def normalize_url(url)
      # Remove protocol if present
      url = url.gsub(/^https?:\/\//, '')
      # Remove www. prefix
      url = url.gsub(/^www\./, '')
      # Remove trailing slash
      url = url.gsub(/\/$/, '')
      # Remove path and query string, keep only domain
      url = url.split('/').first
      url = url.split('?').first
      url
    end

    def extract_domain(url)
      # Extract domain from URL
      normalized = normalize_url(url)
      # Remove port if present
      normalized.split(':').first
    end

    def monitor_dns_queries(interface)
      # Use tcpdump to capture DNS queries on WireGuard interface
      # This requires root privileges
      begin
        # Check if tcpdump is available
        unless system('which tcpdump > /dev/null 2>&1')
          puts "[UrlTracker] tcpdump not found, DNS monitoring disabled"
          return
        end

        # Check if we have permission to capture packets
        unless system('tcpdump --version > /dev/null 2>&1')
          puts "[UrlTracker] No permission to use tcpdump, DNS monitoring disabled"
          puts "[UrlTracker] Run with sudo or add CAP_NET_RAW capability"
          return
        end

        # Build tcpdump command to capture DNS queries
        # -i: interface
        # -n: don't resolve addresses
        # -l: line buffered
        # -A: print packet contents
        # port 53: DNS port
        cmd = "tcpdump -i #{interface} -n -l -A 'port 53 and udp' 2>/dev/null"

        IO.popen(cmd) do |io|
          io.each_line do |line|
            break unless @running

            # Parse DNS query from tcpdump output
            # Look for domain names in DNS queries
            if line =~ /(\w+\.)+[a-zA-Z]{2,}/
              domain = $&
              # Filter out common system domains
              next if domain =~ /^(localhost|127\.0\.0\.1|0\.0\.0\.0)$/
              next if domain =~ /^10\./
              next if domain =~ /^172\.(1[6-9]|2[0-9]|3[01])\./
              next if domain =~ /^192\.168\./

              # Print captured domain
              puts "[UrlTracker] Captured domain: #{domain}"

              # Add domain as URL
              add_url("https://#{domain}")
            end
          end
        end
      rescue => e
        puts "[UrlTracker] Error monitoring DNS: #{e.message}"
        puts e.backtrace.first(3)
      end
    end
  end
end

