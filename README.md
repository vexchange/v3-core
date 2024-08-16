# Reservoir AMM-core

## Setup

### Install global dependencies

This repo uses [foundry](https://github.com/foundry-rs/foundry)
as the main tool for compiling and testing smart contracts. You can install
foundry via:

```shell
curl -L https://foundry.paradigm.xyz | bash
```

For alternative installation options & more details [see the foundry repo](https://github.com/foundry-rs/foundry).

### Install project dependencies

```bash
git submodule update --init --recursive
nvm use
npm ci
npm run install
```

## Building

```bash
forge build
```

## Testing

To run unit tests:

```bash
forge test
```

To run integration tests:

```bash
npm run test:integration
```

To run differential fuzz tests:

```bash
npm run test:differential
```

To run legacy tests:

```bash
npm run test:uniswap
```

## Audits

You can find all audit reports under the audits folder.

V1.0

- [ABDK](./audits/ABDK_ReservoirFi_AMMCore_v_1_0.pdf)

## Production Parameters

- Assumptions when setting an appropriate max change rate: 
  - Oracle manipulation attempts will move prices more than the most violent organic runs
  - So what we need is some 
- Refer to this spreadsheet for detailed [calculations](https://docs.google.com/spreadsheets/d/1oAn8ghqK1MThrgOcHUl8nP_ATTpnlmMqnDtqBXxeHJs/edit#gid=0)

- `ReservoirPair::maxChangeRate`
  - The rates proposed below are derived from most violent price change over a 1-year lookback period from August 2024.
  - BTC-ETH pair
    - Fixed at 0.0012e18 (12 bp/s)
  - BTC-USDC pair 
    - Fixed at 0.0007 (7 bp/s)
  - ETH-USDC pair
    - Fixed at 0.0014e18 (14 bp/s)
  - Stable Pairs
    - Fixed at 0.0001e18 (1 bp/s)

- TWAP Period
    - 15 min for all pairs

- Max price change within one trade
  - Volatile Pairs
    - 2% 
  - Stable Pairs 
    - 0.1%

## Contributing

Are you interested in helping us build the future of Reservoir?
Contribute in these ways:

- For SECURITY related or sensitive bugs, please get in touch with the team
at security@reservoir.fi or on discord instead of opening an issue on github.

- If you find bugs or code errors, you can open a new
[issue ticket here.](https://github.com/reservoir-labs/amm-core/issues/new)

- If you find an issue and would like to submit a fix for said issue, follow
these steps:
  - Start by forking the amm-core repository to your local environment.
  - Make the changes you find necessary to your local repository.
  - Submit your [pull request.](https://github.com/reservoir-labs/amm-core/compare)

- Have questions, or want to interact with the team and the community?
Join our [discord!](https://discord.gg/SZjwsPT7CB)
