#!/bin/bash

set -e

echo "🚀 Setting up VPN Node..."

# Check if Ruby is installed
if ! command -v ruby &> /dev/null; then
    echo "❌ Ruby is not installed. Please install Ruby 3.2.0 or later."
    exit 1
fi

# Check Ruby version compatibility
RUBY_VERSION_MAJOR=$(ruby -v | grep -oP 'ruby (\d+)\.\d+\.\d+' | grep -oP '\d+' | head -1)
RUBY_VERSION_MINOR=$(ruby -v | grep -oP 'ruby \d+\.(\d+)\.\d+' | grep -oP '\d+' | head -1)
if [ "$RUBY_VERSION_MAJOR" -lt 3 ] || ([ "$RUBY_VERSION_MAJOR" -eq 3 ] && [ "$RUBY_VERSION_MINOR" -lt 2 ]); then
    echo "⚠️  Warning: Ruby 3.2.0 or later is recommended. Current version may work but is not tested."
fi

# Check Ruby version
RUBY_VERSION=$(ruby -v | grep -oP '\d+\.\d+\.\d+' | head -1)
echo "✓ Ruby version: $RUBY_VERSION"

# Check if bundler is installed
if ! command -v bundle &> /dev/null; then
    echo "📦 Installing bundler..."
    gem install bundler
fi

# Install dependencies
echo "📦 Installing Ruby dependencies..."
bundle install

# Create keys directory
echo "🔑 Creating keys directory..."
mkdir -p keys
chmod 700 keys

# Check if .env exists
if [ ! -f .env ]; then
    echo "📝 Creating .env file from example.env..."
    cp example.env .env
    echo "⚠️  Please edit .env file with your configuration:"
    echo "   - NODE_ADDRESS: Your node Ethereum address"
    echo "   - PRIVATE_KEY_PATH: Path to your private key"
    echo "   - BACKEND_URL: Backend API URL"
    echo ""
    echo "   After editing .env, generate a key with:"
    echo "   bundle exec rake keygen"
else
    echo "✓ .env file already exists"
fi

# Check if WireGuard is installed (optional, only warn)
if ! command -v wg &> /dev/null; then
    echo "⚠️  WireGuard is not installed. Install it with:"
    echo "   sudo apt update && sudo apt install wireguard wireguard-tools"
else
    echo "✓ WireGuard is installed"
fi

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "1. Edit .env file with your configuration"
echo "2. Generate a key: bundle exec rake keygen"
echo "3. Run the agent: bundle exec rake run"
echo "   Or with Docker: docker-compose up"

