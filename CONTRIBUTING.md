# Contributing

Thanks for helping improve LendGrid.

## Development

```bash
forge install
forge test -vv
forge fmt
```

## Pull requests

1. Branch from `main`
2. Cover lending / interest / liquidation changes with Foundry tests
3. Run `forge test` and `forge fmt` before submitting

## Style

- Solidity `0.8.24`, SafeERC20 and explicit custom errors
- Keep interest math in `uint256` with documented scaling
