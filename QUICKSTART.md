# VPN Node - Hướng dẫn nhanh

> 📖 **Xem hướng dẫn Docker chi tiết:** [DOCKER_GUIDE.md](./DOCKER_GUIDE.md)

## Cách 1: Chạy với Docker (Khuyến nghị)

### Bước 1: Setup môi trường
```bash
# Copy file cấu hình
cp example.env .env

# Chỉnh sửa .env với thông tin của bạn
nano .env  # hoặc vim .env
```

### Bước 2: Tạo private key
```bash
# Tạo key và lưu vào ./keys/node.key
bundle exec rake keygen

# Hoặc nếu chưa có bundle, chạy:
ruby node-agent/bin/keygen -p ./keys/node.key
```

### Bước 3: Cập nhật NODE_ADDRESS trong .env
Sau khi tạo key, bạn sẽ thấy địa chỉ node. Copy và cập nhật vào file `.env`:
```
NODE_ADDRESS=0xYourNodeAddressHere
```

### Bước 4: Build và chạy với Docker
```bash
# Build Docker image
docker build -t vpn-node .

# Hoặc sử dụng script
bash build.sh

# Chạy với docker-compose
docker-compose up -d

# Xem logs
docker-compose logs -f
```

## Cách 2: Chạy trực tiếp trên máy

### Bước 1: Setup
```bash
# Chạy script setup tự động
bash setup.sh

# Hoặc setup thủ công
bundle install
mkdir -p keys
cp example.env .env
```

### Bước 2: Tạo key và cấu hình
```bash
# Tạo private key
bundle exec rake keygen

# Cập nhật NODE_ADDRESS trong .env
nano .env
```

### Bước 3: Cài đặt WireGuard (nếu chưa có)
```bash
sudo apt update
sudo apt install wireguard wireguard-tools
```

### Bước 4: Chạy agent
```bash
# Chạy trực tiếp
bundle exec rake run

# Hoặc chạy như daemon
bundle exec rake daemon
```

## Các lệnh hữu ích

### Rake tasks
```bash
# Setup môi trường
bundle exec rake setup

# Tạo key
bundle exec rake keygen

# Chạy agent
bundle exec rake run

# Chạy như daemon
bundle exec rake daemon

# Build Docker image
bundle exec rake docker_build

# Docker Compose
bundle exec rake docker_up      # Khởi động
bundle exec rake docker_down    # Dừng
bundle exec rake docker_logs    # Xem logs

# Reward
bundle exec rake claim_reward[123]    # Claim reward cho epoch 123
bundle exec rake verify_reward[123]   # Verify reward cho epoch 123
```

### Scripts
```bash
# Setup tự động
bash setup.sh

# Build Docker image
bash build.sh [tag]
```

## Cấu hình môi trường (.env)

Các biến môi trường quan trọng:

- `NODE_ADDRESS`: Địa chỉ Ethereum của node (bắt buộc)
- `PRIVATE_KEY_PATH`: Đường dẫn đến private key (mặc định: ./keys/node.key)
- `BACKEND_URL`: URL của backend API (mặc định: http://localhost:3000)
- `HEARTBEAT_INTERVAL`: Khoảng thời gian gửi heartbeat (giây, mặc định: 30)
- `TRAFFIC_REPORT_INTERVAL`: Khoảng thời gian báo cáo traffic (giây, mặc định: 60)

Để claim rewards, cần thêm:
- `RPC_URL`: Blockchain RPC endpoint
- `REWARD_CONTRACT_ADDRESS`: Địa chỉ Reward contract
- `CONTRACT_ABI_PATH`: (Tùy chọn) Đường dẫn đến contract ABI

## Kiểm tra hoạt động

### Xem logs
```bash
# Docker
docker-compose logs -f

# Trực tiếp
tail -f logs/vpn-node.log  # Nếu có file log
```

### Kiểm tra heartbeat
Agent sẽ tự động gửi heartbeat đến backend mỗi 30 giây (mặc định).

### Kiểm tra traffic
Agent sẽ báo cáo traffic mỗi 60 giây (mặc định).

## Troubleshooting

### Lỗi: "NODE_ADDRESS is required"
- Kiểm tra file `.env` có biến `NODE_ADDRESS` chưa
- Đảm bảo đã tạo key và cập nhật địa chỉ vào `.env`

### Lỗi: "Private key file not found"
- Chạy `bundle exec rake keygen` để tạo key
- Kiểm tra đường dẫn trong `PRIVATE_KEY_PATH`

### Lỗi: "Node address mismatch"
- Đảm bảo `NODE_ADDRESS` trong `.env` khớp với địa chỉ từ private key
- Tạo lại key nếu cần: `bundle exec rake keygen`

### WireGuard không hoạt động trong Docker
- Đảm bảo container có quyền `NET_ADMIN` và `SYS_MODULE`
- Kiểm tra `/dev/net/tun` device được mount
- Sử dụng `network_mode: host` trong docker-compose

## Bảo mật

- **KHÔNG** commit file `.env` hoặc `keys/` vào git
- Private key phải có quyền 600: `chmod 600 keys/node.key`
- Sử dụng Docker secrets hoặc environment variables trong production
- Đảm bảo backend URL sử dụng HTTPS trong production

