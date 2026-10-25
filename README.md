# LendGrid

**Overcollateralized lending pool** — deposit collateral, borrow against LTV, repay, or liquidate unhealthy positions. Oracle-priced health factors with liquidation bonus.

[![CI](https://github.com/kianPk/lendgrid/actions/workflows/ci.yml/badge.svg)](https://github.com/kianPk/lendgrid/actions/workflows/ci.yml)
[![Demo](https://img.shields.io/badge/Demo-kianpk.github.io%2Flendgrid-10b981?style=for-the-badge)](https://kianpk.github.io/lendgrid/)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?style=for-the-badge&logo=solidity)](https://github.com/kianPk/lendgrid)
[![Foundry](https://img.shields.io/badge/Foundry-forge-000000?style=for-the-badge)](https://book.getfoundry.sh/)

> Lab / portfolio protocol — not a mainnet money market.

## Architecture

```text
                    SimplePriceOracle (USD, 8 decimals)
                              │
User ──deposit WETH──▶ LendingPool ◀──seed USDC liquidity── Admin
         │                  │
         ├─ borrow USDC     ├─ healthFactor (1e18)
         ├─ repay           └─ liquidate(user, repayAmount)
         └─ withdraw
```

| Param | Demo default |
|-------|----------------|
| LTV | 75% |
| Liquidation threshold | 80% |
| Liquidation bonus | 5% |

## Quick start

```bash
forge install
forge test -vv
```

## Also in this release

- **Per-second borrow rate** — `setBorrowRateBpsPerSecond` (WAD-scaled bps/s) or utilization-derived APR fallback
- Utilization-aware borrow APR (two-slope kink model)
- Index-based interest accrual + per-user sync
- Liquidation with bonus still intact

## Flows covered in tests

- Deposit → borrow under LTV → repay  
- Revert when borrow exceeds LTV  
- Oracle crash → HF < 1 → liquidate seizes collateral + bonus  
- Partial withdraw while staying healthy  

## Stack

```text
Solidity 0.8.24 · Foundry · OpenZeppelin AccessControl / Pausable / SafeERC20
```

## License

MIT © [kianPk](https://github.com/kianPk)
