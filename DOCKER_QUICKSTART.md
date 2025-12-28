# VPN Node - Hướng dẫn Docker nhanh

Hướng dẫn nhanh để chạy VPN Node với Docker trong 5 phút.

## ⚡ Quick Start

```bash
# 1. Vào thư mục vpn-node
cd vpn-node

# 2. Tạo file cấu hình
cp example.env .env

# 3. Tạo private key (cần Ruby)
bundle install
bundle exec rake keygen

# 4. Cập nhật NODE_ADDRESS trong .env (lấy từ bước 3)

# 5. Build và chạy
docker-compose up -d

# 6. Xem logs
docker-compose logs -f
```

## 📋 Các bước chi tiết

### Bước 1: Tạo file .env

```bash
cp example.env .env
```

### Bước 2: Tạo private key

**Nếu có Ruby trên máy:**
```bash
bundle install
bundle exec rake keygen
```

**Nếu không có Ruby, tạo key trong container:**
```bash
# Build image trước
docker build -t vpn-node:latest .

# Tạo key
docker run --rm -v $(pwd)/keys:/app/keys vpn-node:latest \
  ruby node-agent/bin/keygen -p /app/keys/node.key
```

Sau khi tạo key, bạn sẽ thấy địa chỉ node. Copy địa chỉ này.

### Bước 3: Cấu hình .env

Mở file `.env` và cập nhật:

```env
NODE_ADDRESS=0xYourNodeAddressHere  # Lấy từ bước 2
BACKEND_URL=http://localhost:3000   # URL của backend API
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
# Chạy ở background
docker-compose up -d

# Hoặc chạy ở foreground để xem logs
docker-compose up
```

### Bước 6: Kiểm tra

```bash
# Xem logs
docker-compose logs -f

# Kiểm tra container đang chạy
docker ps | grep vpn-node

# Kiểm tra health
docker inspect --format='{{.State.Health.Status}}' vpn-node
```

## 🛠️ Các lệnh thường dùng

```bash
# Dừng container
docker-compose stop

# Khởi động lại
docker-compose start

# Dừng và xóa
docker-compose down

# Xem logs
docker-compose logs -f

# Vào trong container
docker exec -it vpn-node bash

# Rebuild và restart
docker-compose build && docker-compose up -d
```

## ⚠️ Lưu ý quan trọng

1. **Backend URL**: Nếu backend chạy trên máy khác, thay `localhost` bằng IP của máy đó
2. **Network**: Container sử dụng `network_mode: host` để WireGuard hoạt động
3. **Keys**: File key phải có trong `./keys/node.key` trước khi chạy
4. **Permissions**: Trên Linux có thể cần chạy với `sudo`

## 🔍 Troubleshooting nhanh

**Container không chạy:**
```bash
docker-compose logs --tail=50
```

**Không kết nối được backend:**
- Kiểm tra `BACKEND_URL` trong `.env`
- Đảm bảo backend đang chạy
- Nếu backend trên máy khác, dùng IP thay vì localhost

**Lỗi "Private key not found":**
```bash
ls -la keys/node.key
chmod 600 keys/node.key
```

## 📖 Xem thêm

- **Hướng dẫn Docker chi tiết:** [DOCKER_GUIDE.md](./DOCKER_GUIDE.md)
- **Hướng dẫn đầy đủ:** [README.md](./README.md)
- **Hướng dẫn nhanh:** [QUICKSTART.md](./QUICKSTART.md)

