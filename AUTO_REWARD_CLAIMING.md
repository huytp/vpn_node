# Automatic Reward Claiming

## Overview

VPN Node Agent tự động claim rewards định kỳ khi chạy với Docker Compose. Không cần can thiệp thủ công.

## Configuration

### Environment Variables

Thêm vào `.env` file:

```env
# Required for reward claiming
REWARD_CONTRACT_ADDRESS=0x...
TATUM_POLYGON_AMOY_URL=https://...
TATUM_API_KEY=your_api_key

# Optional: Reward claim interval (seconds)
# Default: 300 (5 minutes)
REWARD_CLAIM_INTERVAL=300
```

### Docker Compose

Các environment variables đã được cấu hình trong `docker-compose.yml`:

```yaml
environment:
  - REWARD_CONTRACT_ADDRESS=${REWARD_CONTRACT_ADDRESS:-}
  - TATUM_POLYGON_AMOY_URL=${TATUM_POLYGON_AMOY_URL:-}
  - TATUM_API_KEY=${TATUM_API_KEY:-}
  - REWARD_CLAIM_INTERVAL=${REWARD_CLAIM_INTERVAL:-300}
```

## How It Works

1. **Agent Startup**
   - Agent khởi tạo `RewardClaimer` nếu `REWARD_CONTRACT_ADDRESS` và RPC URL được cung cấp
   - Nếu không có, reward claiming sẽ bị disable (không ảnh hưởng đến các chức năng khác)

2. **Automatic Claiming Loop**
   - Chạy trong background thread riêng
   - Mỗi `REWARD_CLAIM_INTERVAL` giây (default: 5 phút):
     - Kiểm tra unclaimed rewards từ backend
     - Claim từng reward tự động
     - Update status trên backend sau khi claim thành công

3. **Rate Limiting**
   - RPCClient có rate limiting (3 req/s cho Tatum free tier)
   - Automatic retry với exponential backoff
   - Delay giữa các claims để tránh rate limit

## Usage

### Start with Auto-Claiming

```bash
cd vpn-node
docker-compose up -d
```

Agent sẽ tự động:
- ✅ Start heartbeat loop
- ✅ Start traffic reporting loop
- ✅ Start reward claiming loop (nếu config đầy đủ)

### Check Logs

```bash
docker-compose logs -f vpn-node-1
```

Bạn sẽ thấy:
```
✅ Initializing reward claimer...
💰 Starting reward claim loop (interval: 300s)
💰 Found 2 unclaimed reward(s), claiming...
💰 Claiming epoch 225 (5000 tokens)...
   ✅ Claimed successfully!
      TX: 0x...
```

### Disable Auto-Claiming

Để disable auto-claiming, chỉ cần không set `REWARD_CONTRACT_ADDRESS`:

```env
# Comment out or remove
# REWARD_CONTRACT_ADDRESS=0x...
```

Agent sẽ log:
```
⚠️  Reward claiming disabled (REWARD_CONTRACT_ADDRESS not set)
```

## Manual Claiming

Bạn vẫn có thể claim thủ công nếu muốn:

```bash
cd vpn-node
bin/claim-reward [epoch_id]
```

## Configuration Options

### REWARD_CLAIM_INTERVAL

Thời gian giữa các lần kiểm tra rewards (seconds):

```env
# Check every 5 minutes (default)
REWARD_CLAIM_INTERVAL=300

# Check every 10 minutes
REWARD_CLAIM_INTERVAL=600

# Check every minute (not recommended, may hit rate limits)
REWARD_CLAIM_INTERVAL=60
```

**Recommendation**:
- 300s (5 phút) cho production
- 600s (10 phút) nếu muốn tiết kiệm RPC calls

## Security

✅ **Private keys never leave the node**
- Private key chỉ được sử dụng local để sign transactions
- Không bao giờ gửi lên server

✅ **Rate limiting built-in**
- Tự động handle rate limits
- Retry với exponential backoff

✅ **Error handling**
- Errors không làm crash agent
- Logs errors để debug

## Troubleshooting

### "Reward claiming disabled"
**Cause**: `REWARD_CONTRACT_ADDRESS` hoặc RPC URL không được set
**Solution**: Thêm vào `.env`:
```env
REWARD_CONTRACT_ADDRESS=0x...
TATUM_POLYGON_AMOY_URL=https://...
```

### "Failed to fetch proof"
**Cause**: Backend không accessible hoặc epoch chưa committed
**Solution**:
- Check `BACKEND_URL` trong `.env`
- Verify backend đang chạy
- Check epoch đã được settled chưa

### "Rate limit hit (429)"
**Cause**: Quá nhiều RPC calls
**Solution**:
- Tăng `REWARD_CLAIM_INTERVAL` lên 600s hoặc hơn
- RPCClient sẽ tự động retry, nhưng tốt hơn là giảm frequency

### "Transaction failed"
**Cause**: Gas issues, network problems, hoặc contract revert
**Solution**:
- Check Polygonscan để xem chi tiết error
- Verify contract address đúng
- Check node có đủ MATIC để pay gas

## Monitoring

### Check Claim Status

```bash
# From node
docker-compose exec vpn-node-1 ruby -e "
  require_relative 'node-agent/lib/signer'
  require_relative 'node-agent/lib/reward_claimer'
  # ... check pending rewards
"

# Or use API
curl "http://localhost:3000/rewards/unclaimed?node=0x..."
```

### View Transaction History

Check Polygonscan:
```
https://amoy.polygonscan.com/address/<NODE_ADDRESS>
```

## Summary

✅ **Automatic**: Rewards được claim tự động khi docker compose up
✅ **Secure**: Private keys never leave the node
✅ **Configurable**: Adjust interval via environment variable
✅ **Resilient**: Error handling và rate limiting built-in
✅ **Optional**: Có thể disable nếu không muốn auto-claim

Node operators chỉ cần set environment variables và start docker-compose. Rewards sẽ được claim tự động! 🎉

