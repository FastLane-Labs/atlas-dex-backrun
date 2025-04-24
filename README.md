# Atlas DEX Backrun Module

## Instal Dependencies

```bash
forge install
```

## Run tests

Tests must be ran on Base mainnet.

```bash
forge test --rpc-url <BASE_MAINNET_RPC_URL>
```

## Deploy modules

Create a `.env` file, patterned after `.env.example`. Fill in the values.

Run the following commands to deploy the dApp controls.

```bash
# For UniswapV2DAppControl
npm run deploy-uniswap-v2-module

# For UniswapV3DAppControl
npm run deploy-uniswap-v3-module
```
