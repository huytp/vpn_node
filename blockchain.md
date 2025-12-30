# Blockchain Contracts

## Mục tiêu
- Định danh node
- Trả thưởng PAY-PER-TRAFFIC
- Quản lý vesting cho team
- Không custody tiền

## Token Distribution

Total Supply: **1,000,000,000 DEVPN** (1 tỷ tokens)

| Nhóm                    |       % |        Số lượng | Giữ bởi                                   |
| ----------------------- | ------: | --------------: | ----------------------------------------- |
| **Node rewards**        | **90%** | **900,000,000** | Reward smart contract (mint theo traffic) |
| **Core team (vesting)** | **10%** | **100,000,000** | Vesting 4 năm (cliff 12 tháng)            |

## Chain
- Polygon Amoy Testnet (EVM L2)

## Smart Contracts

### 1️⃣ DEVPNToken.sol
Main ERC20 token contract với:
- Total supply: 1 tỷ tokens
- Distribution pools tracking
- Authorized minters cho node rewards

**Functions:**
- `mintNodeReward(address, uint256)`: Mint từ node rewards pool (90%)
- `setRewardContract(address)`: Set Reward contract
- `setVestingContract(address)`: Set Vesting contract
- `setRewardMinter(address, bool)`: Add/remove reward minter
- `initializeDistribution(address)`: Initialize và transfer tokens to Vesting
- `getRemainingNodeRewards()`: Check remaining pool
- `getDistributionStatus()`: Get all pool statuses

### 2️⃣ NodeRegistry.sol
Quản lý đăng ký và trạng thái của VPN nodes:
- `registerNode()`: Đăng ký node mới
- `disableNode(address)`: Vô hiệu hóa node
- `isActive(address)`: Kiểm tra trạng thái node

### 3️⃣ Reward.sol
Quản lý reward distribution sử dụng Merkle tree:
- `commitEpoch(uint, bytes32)`: Commit merkle root cho epoch (owner only)
- `claimReward(uint, uint, bytes32[])`: Claim reward với merkle proof
- Mints tokens từ node rewards pool (90%)

**Events:**
- `EpochCommitted(uint indexed epoch, bytes32 merkleRoot)`
- `RewardClaimed(address indexed recipient, uint epoch, uint amount)`

### 4️⃣ Vesting.sol
Manages vesting cho Core Team:
- **Core Team**: 100M tokens, 4 năm vesting, 12 tháng cliff

**Functions:**
- `createVestingSchedule()`: Tạo vesting schedule
- `release(address)`: Release vested tokens
- `getReleasableAmount(address)`: Check releasable amount
- `getVestedAmount(address)`: Get total vested amount
- `batchCreateVestingSchedules()`: Batch create schedules

## Deployment Order

1. **DEVPNToken** - Deploy token contract
2. **NodeRegistry** - Deploy node registry
3. **Reward** - Deploy reward contract (link to token)
4. **Vesting** - Deploy vesting contract (receive tokens)

## Initial Setup

Sau khi deploy, chạy `setup-contracts.rb` để:
1. Set Reward contract trong DEVPNToken: `setRewardContract(rewardAddress)`
2. Initialize distribution: `initializeDistribution(vestingAddress)` - Transfer 100M tokens to Vesting
3. Set Vesting contract: `setVestingContract(vestingAddress)`

## Security

- Owner controls cho initial setup
- Vesting prevents early dumping
- Merkle proofs cho efficient reward distribution
- Only authorized minters có thể mint rewards

## Usage

### Deploy Contracts

```bash
# Compile contracts
npm run compile

# Deploy all contracts
ruby scripts/deploy.rb
```

### Setup Contracts

```bash
# Configure contracts (set addresses, initialize distribution)
ruby scripts/setup-contracts.rb
```

### Check Contract Ownership

```bash
# Verify you are the owner of contracts
ruby scripts/check-contract-owner.rb
```

## Contract Addresses

Sau khi deploy, addresses sẽ được lưu vào `.env`:
- `DEVPN_TOKEN_ADDRESS`
- `NODE_REGISTRY_ADDRESS`
- `REWARD_ADDRESS`
- `VESTING_ADDRESS`
