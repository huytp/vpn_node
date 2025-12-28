# VPN Node (Ruby)

## Stack
- WireGuard
- Linux (Ubuntu)
- Ruby agent

## Cấu trúc

### wireguard/
Cấu hình và quản lý WireGuard

### node-agent/
Agent chạy trên VPS node

#### lib/signer.rb
- Ký các metrics và traffic data
- Sử dụng node private key (ECDSA với eth gem)
- Generate new key pairs

#### lib/traffic_meter.rb
- Đếm MB traffic đã forward
- Session-based
- Signed by node key

#### lib/heartbeat.rb
- Gửi heartbeat định kỳ
- Payload:
```json
{
  "node": "0xNODE",
  "latency": 42,
  "loss": 0.01,
  "bandwidth": 120,
  "uptime": 3600,
  "signature": "0x..."
}
```

#### lib/reward_claimer.rb
- Tự động claim rewards từ blockchain
- Fetch merkle proof từ backend
- Claim reward on-chain

#### lib/reward_verifier.rb
- Verify reward calculation
- Check traffic records
- Verify signatures

#### lib/wireguard.rb
- WireGuard configuration helpers
- Generate key pairs
- Manage interfaces

## Installation

### Prerequisites
- Ruby 3.2.0+
- WireGuard installed on system
- Linux/Ubuntu

### Setup

1. **Install WireGuard** (if not already installed):
```bash
sudo apt update
sudo apt install wireguard wireguard-tools
```

2. **Install Ruby dependencies**:
```bash
bundle install
```

3. **Generate private key** (if needed):
```bash
bundle exec rake keygen
# hoặc
ruby node-agent/bin/keygen -p ./keys/node.key
```

4. **Configure environment**:
```bash
export NODE_ADDRESS="0xYourNodeAddress"
export PRIVATE_KEY_PATH="./keys/node.key"
export BACKEND_URL="http://localhost:3000"
export HEARTBEAT_INTERVAL="30"
export TRAFFIC_REPORT_INTERVAL="60"
export WG_INTERFACE="wg0"
export WG_CONFIG_PATH="/etc/wireguard/wg0.conf"

# For reward claiming (optional)
export RPC_URL="https://polygon-mumbai.g.alchemy.com/v2/YOUR_KEY"
export REWARD_CONTRACT_ADDRESS="0x..."
export CONTRACT_ABI_PATH="./contracts/Reward.json"
```

Hoặc tạo file `.env`:
```bash
cp example.env .env
# Edit .env với các giá trị của bạn
```

5. **Run the agent**:
```bash
bundle exec rake run
# hoặc
ruby node-agent/bin/node-agent
```

## Configuration

### Environment Variables

- `NODE_ADDRESS`: Ethereum address của node (required)
- `PRIVATE_KEY_PATH`: Path đến private key file (default: ./keys/node.key)
- `BACKEND_URL`: URL của backend API (default: http://localhost:3000)
- `HEARTBEAT_INTERVAL`: Interval để gửi heartbeat (seconds, default: 30)
- `TRAFFIC_REPORT_INTERVAL`: Interval để report traffic (seconds, default: 60)
- `WG_INTERFACE`: WireGuard interface name (default: wg0)
- `WG_CONFIG_PATH`: Path đến WireGuard config file (default: /etc/wireguard/wg0.conf)
- `RPC_URL`: Blockchain RPC endpoint (for reward claiming)
- `REWARD_CONTRACT_ADDRESS`: Reward contract address (for reward claiming)
- `CONTRACT_ABI_PATH`: Path to contract ABI file (optional)

## Features

### Heartbeat
- Gửi metrics định kỳ đến backend
- Metrics: latency, loss, bandwidth, uptime
- Tất cả metrics được ký bằng node private key

### Traffic Meter
- Đếm traffic theo session
- Track bytes in/out
- Tạo signed traffic records
- Report traffic theo epoch

### Signer
- ECDSA signing với Ethereum-compatible keys (sử dụng `eth` gem)
- Sign messages và JSON data
- Generate new key pairs

### Reward Claiming
- Tự động check và claim rewards mỗi 5 phút
- Fetch merkle proof từ backend
- Claim reward on-chain
- Verify reward calculation

## Reward Claiming

### Automatic Claiming
Agent tự động check và claim rewards mỗi 5 phút nếu có cấu hình blockchain:
- `RPC_URL`: RPC endpoint (Polygon, Base, Arbitrum)
- `REWARD_CONTRACT_ADDRESS`: Address của Reward contract
- `CONTRACT_ABI_PATH`: (Optional) Path đến contract ABI

### Manual Claiming
```bash
# Claim specific epoch
ruby node-agent/bin/claim-reward -e 123

# Claim all pending rewards
ruby node-agent/bin/claim-reward
```

### Verify Reward
```bash
# Chạy trong Docker container (khuyến nghị)
docker exec vpn-node-1 ruby node-agent/bin/verify-reward -e 123

# Hoặc chạy từ host (cần set environment variables)
export NODE_ADDRESS=0x569466705D52084149ed610ff3D95Ea4318876cD
export PRIVATE_KEY_PATH=./keys/node1.key
export BACKEND_URL=http://localhost:3000
ruby node-agent/bin/verify-reward -e 123
```

## WireGuard Integration

Agent có thể:
- Generate WireGuard key pairs
- Write WireGuard config files
- Bring up/down interfaces
- Get interface statistics

## Running as Daemon

Sử dụng `daemons` gem để chạy như daemon:

```bash
bundle exec rake daemon
```

## Docker

```bash
docker build -t vpn-node .
docker run -e NODE_ADDRESS=0x... -v $(pwd)/keys:/app/keys vpn-node
```

## Security

- Private keys được lưu local, không gửi lên server
- Tất cả metrics và traffic records được ký
- Backend verify signatures trước khi accept data
- File permissions (0600) cho private keys
- Reward verification endpoint cho phép node verify calculation

## Development

```bash
# Install dependencies
bundle install

# Run tests (if any)
# bundle exec rspec

# Run with pry for debugging
pry -r ./node-agent/lib/vpn_node.rb
```

## Reward Flow

1. **Node hoạt động** → Gửi traffic records → Backend lưu
2. **Mỗi 1 giờ** → Backend settle epoch → Tính reward → Build Merkle tree → Commit lên blockchain
3. **Node check rewards** → Lấy proof từ Backend → Claim trên blockchain → Nhận token DEVPN

## API Endpoints Used

- `POST /nodes/heartbeat` - Gửi heartbeat
- `GET /rewards/proof?node=0x...&epoch=123` - Lấy merkle proof
- `GET /rewards/epochs` - Lấy danh sách epochs
- `GET /rewards/verify/:epoch_id?node=0x...` - Verify reward calculation
