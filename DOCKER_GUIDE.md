# Hướng dẫn chạy VPN Node bằng Docker

Hướng dẫn chi tiết để chạy VPN Node sử dụng Docker và Docker Compose.

## 📋 Yêu cầu hệ thống

- Docker Engine 20.10+ hoặc Docker Desktop
- Docker Compose 2.0+ (tùy chọn, nhưng khuyến nghị)
- Quyền root/sudo để mount WireGuard (nếu chạy trên Linux)
- Ít nhất 512MB RAM
- 1GB dung lượng ổ đĩa

## 🚀 Cách 1: Sử dụng Docker Compose (Khuyến nghị)

### Bước 1: Chuẩn bị môi trường

```bash
cd vpn-node

# Tạo file .env từ template
cp example.env .env
```

### Bước 2: Tạo private key

Bạn có thể tạo key trước khi chạy Docker hoặc tạo trong container:

**Cách A: Tạo key trên máy host (khuyến nghị)**

```bash
# Cài đặt Ruby dependencies (nếu chưa có)
bundle install

# Tạo private key
bundle exec rake keygen
# hoặc
ruby node-agent/bin/keygen -p ./keys/node.key
```

Sau khi tạo key, bạn sẽ thấy địa chỉ node. Copy địa chỉ này.

**Cách B: Tạo key trong container**

```bash
# Chạy container tạm thời để tạo key
docker run --rm -v $(pwd)/keys:/app/keys vpn-node:latest \
  ruby node-agent/bin/keygen -p /app/keys/node.key
```

### Bước 3: Cấu hình file .env

Mở file `.env` và cập nhật các giá trị:

```bash
nano .env
# hoặc
vim .env
```

Các biến quan trọng:

```env
# Bắt buộc: Địa chỉ node (lấy từ bước tạo key)
NODE_ADDRESS=0xYourNodeAddressHere

# Backend API URL
BACKEND_URL=http://localhost:3000

# Nếu backend chạy trên máy khác, sử dụng IP của máy đó
# BACKEND_URL=http://192.168.1.100:3000

# Tùy chọn: Cấu hình blockchain để claim rewards
RPC_URL=https://polygon-mumbai.g.alchemy.com/v2/YOUR_KEY
REWARD_CONTRACT_ADDRESS=0x...
```

### Bước 4: Build Docker image

```bash
# Sử dụng script
bash build.sh

# Hoặc build trực tiếp
docker build -t vpn-node:latest .
```

### Bước 5: Chạy container

```bash
# Chạy ở chế độ background (detached)
docker-compose up -d

# Hoặc chạy ở foreground để xem logs
docker-compose up
```

### Bước 6: Kiểm tra logs

```bash
# Xem logs real-time
docker-compose logs -f

# Xem logs của container
docker logs -f vpn-node

# Xem 100 dòng logs cuối
docker-compose logs --tail=100
```

## 🐳 Cách 2: Sử dụng Docker Run trực tiếp

Nếu không muốn dùng Docker Compose, bạn có thể chạy trực tiếp với `docker run`:

### Build image

```bash
docker build -t vpn-node:latest .
```

### Chạy container

```bash
docker run -d \
  --name vpn-node \
  --restart unless-stopped \
  --network host \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --device /dev/net/tun \
  -v $(pwd)/keys:/app/keys:ro \
  -v /etc/wireguard:/etc/wireguard:ro \
  --env-file .env \
  vpn-node:latest
```

**Giải thích các tham số:**

- `-d`: Chạy ở chế độ background (detached)
- `--name vpn-node`: Tên container
- `--restart unless-stopped`: Tự động khởi động lại khi container dừng
- `--network host`: Sử dụng network mode host (cần cho WireGuard)
- `--cap-add NET_ADMIN --cap-add SYS_MODULE`: Quyền cần thiết cho WireGuard
- `--device /dev/net/tun`: Mount TUN device cho WireGuard
- `-v $(pwd)/keys:/app/keys:ro`: Mount thư mục keys (read-only)
- `-v /etc/wireguard:/etc/wireguard:ro`: Mount WireGuard config (read-only)
- `--env-file .env`: Load biến môi trường từ file .env

## 📊 Quản lý Container

### Xem trạng thái

```bash
# Xem container đang chạy
docker ps

# Xem tất cả container (kể cả đã dừng)
docker ps -a

# Xem thông tin chi tiết
docker inspect vpn-node
```

### Dừng và khởi động lại

```bash
# Dừng container
docker-compose stop
# hoặc
docker stop vpn-node

# Khởi động lại
docker-compose start
# hoặc
docker start vpn-node

# Khởi động lại container
docker-compose restart
# hoặc
docker restart vpn-node
```

### Xóa container

```bash
# Dừng và xóa container
docker-compose down
# hoặc
docker stop vpn-node && docker rm vpn-node

# Xóa cả image
docker rmi vpn-node:latest
```

### Vào trong container

```bash
# Mở shell trong container
docker exec -it vpn-node bash

# Chạy lệnh trong container
docker exec vpn-node ruby -v
```

## 🔍 Kiểm tra hoạt động

### Kiểm tra logs

```bash
# Xem logs real-time
docker-compose logs -f vpn-node

# Xem logs với timestamp
docker-compose logs -f -t vpn-node

# Tìm kiếm trong logs
docker-compose logs | grep "Heartbeat"
```

### Kiểm tra health check

```bash
# Xem health status
docker inspect --format='{{.State.Health.Status}}' vpn-node

# Xem health check logs
docker inspect --format='{{json .State.Health}}' vpn-node | jq
```

### Kiểm tra kết nối backend

```bash
# Test kết nối từ container
docker exec vpn-node curl -I http://localhost:3000/health

# Nếu backend chạy trên máy khác, thay localhost bằng IP
```

## 🔧 Troubleshooting

### Lỗi: "Cannot connect to backend"

**Nguyên nhân:** Container không thể kết nối đến backend.

**Giải pháp:**

1. Kiểm tra BACKEND_URL trong `.env`:
   ```bash
   # Nếu backend chạy trên máy host
   BACKEND_URL=http://host.docker.internal:3000

   # Nếu backend chạy trên máy khác
   BACKEND_URL=http://192.168.1.100:3000

   # Nếu dùng network_mode: host
   BACKEND_URL=http://localhost:3000
   ```

2. Kiểm tra firewall:
   ```bash
   # Cho phép kết nối từ container
   sudo ufw allow 3000/tcp
   ```

### Lỗi: "Private key file not found"

**Nguyên nhân:** File key không tồn tại hoặc không được mount đúng.

**Giải pháp:**

```bash
# Kiểm tra file key có tồn tại
ls -la keys/node.key

# Đảm bảo file có quyền đọc
chmod 600 keys/node.key

# Kiểm tra mount trong container
docker exec vpn-node ls -la /app/keys/
```

### Lỗi: "Node address mismatch"

**Nguyên nhân:** NODE_ADDRESS trong `.env` không khớp với địa chỉ từ private key.

**Giải pháp:**

```bash
# Kiểm tra địa chỉ từ key
docker exec vpn-node ruby -e "require 'eth'; key = Eth::Key.new(priv: File.read('/app/keys/node.key')); puts key.address"

# Cập nhật NODE_ADDRESS trong .env cho khớp
```

### Lỗi: "Permission denied" với WireGuard

**Nguyên nhân:** Container thiếu quyền cần thiết.

**Giải pháp:**

1. Đảm bảo docker-compose.yml có:
   ```yaml
   cap_add:
     - NET_ADMIN
     - SYS_MODULE
   devices:
     - /dev/net/tun
   ```

2. Trên Linux, có thể cần chạy với sudo:
   ```bash
   sudo docker-compose up -d
   ```

### Container tự động dừng

**Kiểm tra logs để tìm nguyên nhân:**

```bash
docker-compose logs --tail=50 vpn-node
```

**Các nguyên nhân thường gặp:**

1. Lỗi cấu hình trong `.env`
2. Không kết nối được backend
3. Private key không hợp lệ
4. Thiếu dependencies

### Xem logs chi tiết

```bash
# Xem tất cả logs
docker-compose logs vpn-node

# Xem logs với timestamp
docker-compose logs -t vpn-node

# Xem logs real-time
docker-compose logs -f vpn-node

# Xem logs của 100 dòng cuối
docker-compose logs --tail=100 vpn-node
```

## 🔄 Cập nhật Container

### Cập nhật code mới

```bash
# 1. Pull code mới (nếu dùng git)
git pull

# 2. Rebuild image
docker-compose build

# 3. Khởi động lại với image mới
docker-compose up -d
```

### Cập nhật cấu hình

```bash
# 1. Sửa file .env
nano .env

# 2. Khởi động lại container để load cấu hình mới
docker-compose restart
```

## 📝 Các lệnh hữu ích

### Xem resource usage

```bash
# Xem CPU, memory usage
docker stats vpn-node
```

### Backup keys

```bash
# Backup thư mục keys
tar -czf keys-backup-$(date +%Y%m%d).tar.gz keys/
```

### Export logs

```bash
# Export logs ra file
docker-compose logs vpn-node > vpn-node-logs.txt
```

### Chạy lệnh rake trong container

```bash
# Claim reward
docker exec vpn-node bundle exec rake claim_reward[123]

# Verify reward
docker exec vpn-node bundle exec rake verify_reward[123]
```

## 🎯 Production Deployment

### Sử dụng Docker Compose với production config

Tạo file `docker-compose.prod.yml`:

```yaml
version: '3.8'

services:
  vpn-node:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: vpn-node
    restart: always
    environment:
      - NODE_ADDRESS=${NODE_ADDRESS}
      - BACKEND_URL=${BACKEND_URL}
      # ... các biến khác
    volumes:
      - ./keys:/app/keys:ro
      - /etc/wireguard:/etc/wireguard:ro
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    env_file:
      - .env.production
```

Chạy với:

```bash
docker-compose -f docker-compose.prod.yml up -d
```

### Sử dụng Docker Secrets (cho production)

```bash
# Tạo secret cho private key
echo "your-private-key" | docker secret create node_private_key -

# Sử dụng trong docker-compose.yml
secrets:
  node_private_key:
    external: true
```

## ✅ Checklist trước khi chạy

- [ ] Docker và Docker Compose đã cài đặt
- [ ] File `.env` đã được tạo và cấu hình
- [ ] Private key đã được tạo trong `keys/node.key`
- [ ] `NODE_ADDRESS` trong `.env` khớp với địa chỉ từ key
- [ ] Backend API đang chạy và có thể truy cập
- [ ] WireGuard đã được cấu hình (nếu cần)
- [ ] Firewall đã được cấu hình đúng
- [ ] Container có đủ quyền (NET_ADMIN, SYS_MODULE)

## 🆘 Hỗ trợ

Nếu gặp vấn đề, hãy:

1. Kiểm tra logs: `docker-compose logs -f`
2. Kiểm tra health status: `docker inspect vpn-node`
3. Xem file README.md để biết thêm chi tiết
4. Kiểm tra file QUICKSTART.md cho hướng dẫn cơ bản

