require 'eth'
require 'json'
require 'fileutils'

module VPNNode
  class Signer
    attr_reader :private_key, :address

    def initialize(private_key_path)
      load_private_key(private_key_path)
      @address = Eth::Key.new(priv: @private_key).address.to_s
    end

    def sign(data)
      key = Eth::Key.new(priv: @private_key)
      message = data.is_a?(Hash) ? data.to_json : data.to_s
      signature = key.personal_sign(message)
      "0x#{signature}"
    end

    def sign_json(data)
      sign(data)
    end

    def self.generate_key(path)
      key = Eth::Key.new
      private_key_hex = key.private_hex

      # Create directory if it doesn't exist
      FileUtils.mkdir_p(File.dirname(path))

      # Save private key
      File.write(path, private_key_hex)
      File.chmod(0o600, path)

      # Return address
      key.address.to_s
    end

    private

    def load_private_key(path)
      key_content = File.read(path).strip
      # Remove 0x prefix if present
      key_content = key_content[2..-1] if key_content.start_with?('0x')
      @private_key = key_content
    end
  end
end

