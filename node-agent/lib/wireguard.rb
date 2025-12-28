require 'fileutils'

module VPNNode
  module WireGuard
    class Config
      attr_accessor :interface, :private_key, :address, :listen_port, :peers

      def initialize(interface: 'wg0')
        @interface = interface
        @peers = []
      end

      def add_peer(public_key:, allowed_ips: nil, endpoint: nil)
        @peers << {
          public_key: public_key,
          allowed_ips: allowed_ips,
          endpoint: endpoint
        }
      end

      def to_s
        config = "[Interface]\n"
        config += "PrivateKey = #{@private_key}\n" if @private_key
        config += "Address = #{@address}\n" if @address
        config += "ListenPort = #{@listen_port}\n" if @listen_port
        config += "\n"

        @peers.each_with_index do |peer, i|
          config += "[Peer]\n"
          config += "PublicKey = #{peer[:public_key]}\n"
          config += "AllowedIPs = #{peer[:allowed_ips]}\n" if peer[:allowed_ips]
          config += "Endpoint = #{peer[:endpoint]}\n" if peer[:endpoint]
          config += "\n"
        end

        config
      end

      def save(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, to_s)
        File.chmod(0600, path)
      end
    end

    def self.generate_key_pair
      private_key = `wg genkey`.strip
      public_key = `echo "#{private_key}" | wg pubkey`.strip
      [private_key, public_key]
    end

    def self.up_interface(interface)
      system("wg-quick up #{interface}")
    end

    def self.down_interface(interface)
      system("wg-quick down #{interface}")
    end

    def self.get_stats(interface)
      output = `wg show #{interface} transfer 2>/dev/null`.strip
      # Parse output (format: "public_key\tbytes_received\tbytes_sent")
      # For simplicity, return hash
      stats = {}
      output.split("\n").each do |line|
        parts = line.split("\t")
        next if parts.length < 3
        stats[parts[0]] = {
          bytes_received: parts[1].to_i,
          bytes_sent: parts[2].to_i
        }
      end
      stats
    end
  end
end

