# Traffic Reporting Flow - Cách Gửi Traffic và Tính Reward

## 📊 Cách Traffic Được Gửi Đến Server

### 1. **Traffic Tracking (Tích Lũy)**
- Node agent theo dõi traffic từ WireGuard interface
- Traffic được tích lũy trong `TrafficMeter.Session`:
  - `bytes_in`: Bytes nhận vào
  - `bytes_out`: Bytes gửi đi
  - `last_sent_bytes`: Traffic đã gửi lên backend (để tính delta)

### 2. **Periodic Reporting (Mỗi 30 giây)**
```ruby
# File: vpn-node/node-agent/lib/agent.rb
def traffic_report_loop
  loop do
    sleep 30
    active_sessions = @traffic_meter.get_active_sessions
    @traffic_sender.send_traffic_records_batch(active_sessions, epoch_id)
  end
end
```

### 3. **Delta-Based Reporting (Chỉ Gửi Chênh Lệch)**
**VẤN ĐỀ CŨ:** Gửi tổng tích lũy → Trùng lặp
- T=0s: Gửi 10MB (tổng)
- T=10s: Gửi 25MB (tổng) → Backend SUM = 35MB ❌ (sai)
- T=20s: Gửi 40MB (tổng) → Backend SUM = 75MB ❌ (sai)

**GIẢI PHÁP MỚI:** Chỉ gửi delta (chênh lệch)
- T=0s: Gửi 10MB (delta từ 0)
- T=30s: Gửi 15MB (delta từ 10MB) → Backend SUM = 25MB ✅
- T=60s: Gửi 15MB (delta từ 25MB) → Backend SUM = 40MB ✅

### 4. **Implementation**

#### TrafficMeter tạo record với delta:
```ruby
# File: vpn-node/node-agent/lib/traffic_meter.rb
def create_traffic_record(session_id, epoch_id)
  session = @sessions[session_id]
  delta_mb = session.delta_mb  # Chỉ lấy chênh lệch

  {
    session_id: session_id,
    traffic_mb: delta_mb,  # Delta, không phải total
    epoch_id: epoch_id,
    timestamp: Time.now.to_i,
    signature: ...
  }
end
```

#### Sau khi gửi thành công, đánh dấu đã gửi:
```ruby
# File: vpn-node/node-agent/lib/traffic_sender.rb
if response.success?
  # Đánh dấu traffic đã gửi
  @traffic_meter.mark_traffic_sent(session_id)
end
```

## 💰 Cách Tính Tổng Traffic Để Tính Reward

### 1. **Backend Lưu Tất Cả Records**
Mỗi lần node gửi delta traffic, backend tạo một `TrafficRecord`:
```ruby
# File: backend/app/controllers/nodes/traffic_controller.rb
TrafficRecord.create!(
  node: node,
  vpn_connection: vpn_connection,
  epoch_id: epoch_id,
  traffic_mb: traffic_data[:traffic_mb],  # Delta traffic
  signature: signature
)
```

### 2. **Tính Tổng Traffic Cho Epoch**
```ruby
# File: backend/app/models/epoch.rb
def calculate_rewards_with_eligibility
  traffic_records.group_by(&:node_id).each do |node_id, records|
    # Lọc chỉ các records đủ điều kiện
    eligible_records = records.select { |r| r.reward_eligible }

    # SUM tất cả delta traffic = tổng traffic thực tế
    total_traffic = eligible_records.sum(&:traffic_mb)

    # Tính reward
    reward_amount = (total_traffic * quality * reputation * 1000).to_i
  end
end
```

### 3. **Công Thức Reward**
```
Reward = Total_Traffic_MB × Quality_Score × Reputation_Score × 1000
```

Trong đó:
- `Total_Traffic_MB`: SUM của tất cả delta traffic records trong epoch
- `Quality_Score`: Điểm chất lượng node (0-100)
- `Reputation_Score`: Điểm danh tiếng node (0-100)

## ✅ Kiểm Tra Trùng Lặp

### **Cách Mới Đã Giải Quyết:**
1. ✅ **Delta-based**: Chỉ gửi chênh lệch, không gửi tổng tích lũy
2. ✅ **Mark as sent**: Đánh dấu traffic đã gửi sau khi thành công
3. ✅ **Backend SUM**: Backend SUM tất cả delta = tổng traffic chính xác

### **Ví Dụ Thực Tế:**

**Session bắt đầu với 0MB:**
```
T=0s:    Traffic tích lũy = 10MB  → Gửi delta = 10MB  → Backend: 10MB
T=30s:  Traffic tích lũy = 25MB → Gửi delta = 15MB  → Backend: 25MB (10+15)
T=60s:  Traffic tích lũy = 40MB → Gửi delta = 15MB  → Backend: 40MB (10+15+15)
T=90s:  Traffic tích lũy = 50MB → Gửi delta = 10MB  → Backend: 50MB (10+15+15+10)
```

**Tổng traffic thực tế = 50MB** ✅
**Backend SUM = 10+15+15+10 = 50MB** ✅

## 🔍 Debugging

### Kiểm tra traffic đã gửi:
```ruby
# Trong node agent
session = @traffic_meter.get_session(session_id)
puts "Total: #{session.total_mb} MB"
puts "Last sent: #{session.last_sent_bytes / 1024.0 / 1024.0} MB"
puts "Delta: #{session.delta_mb} MB"
```

### Kiểm tra records trong backend:
```ruby
# Trong Rails console
node = Node.find_by(address: "0x...")
epoch = Epoch.find_by(epoch_id: 1)
records = epoch.traffic_records.where(node: node)
puts "Total records: #{records.count}"
puts "Total traffic: #{records.sum(:traffic_mb)} MB"
```

## 📝 Lưu Ý

1. **Traffic = 0**: Không gửi (đã được filter)
2. **Session kết thúc**: Gửi delta cuối cùng trước khi xóa session
3. **Network error**: Nếu gửi thất bại, delta sẽ được gửi lại ở lần sau
4. **Epoch change**: Khi epoch thay đổi, vẫn gửi delta cho epoch mới

