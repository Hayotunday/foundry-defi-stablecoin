# Foundry DeFi Stablecoin

A Foundry-based decentralized stablecoin prototype designed around the idea of minting a dollar-pegged token using overcollateralized crypto assets. This project implements a minimal stablecoin system where collateral is deposited into an engine, then used to mint a stable asset while staying above a health threshold.

## What the product does
This project creates a decentralized stablecoin system where users can lock supported collateral, such as ETH and BTC, and mint a stablecoin pegged to USD. The protocol keeps the system solvent by enforcing collateral ratios and liquidation safeguards.

The core flow is:
- deposit supported collateral
- mint DSC against that collateral
- redeem collateral when debt is reduced
- liquidate unsafe positions if the collateral ratio falls too low

## The problem it solves
A stablecoin needs to maintain value and solvency even in volatile markets. Without strong collateral rules, minting can create under-collateralized debt. This system addresses that by:
- requiring overcollateralization
- checking health factor before minting or redeeming
- limiting how much stablecoin can be generated against deposited assets
- enabling liquidations when a user falls below the required threshold

## My specific contribution
I implemented the stablecoin core logic and the collateral engine around it. This includes the stablecoin token contract, the engine that manages collateral, price-feed integration, minting/redeeming logic, health factor checks, and deployment configuration.

## Architecture
The repo is organized into a standard Foundry setup:

- `src/DecentralizedStableCoin.sol` — the DSC ERC20 token
- `src/DSCEngine.sol` — collateral management, minting, redemption, liquidation logic
- `src/libraries/OracleLib.sol` — helper logic for Chainlink price data
- `script/DeployDSC.s.sol` — deployment flow
- `script/HelperConfig.s.sol` — network config and mock setup
- `test/` — unit and invariant tests for the protocol
- `lib/` — external libraries such as OpenZeppelin and Chainlink dependencies

## Technologies
- Solidity
- Foundry
- Forge testing
- OpenZeppelin ERC20 and ownership logic
- Chainlink price feeds
- Mock aggregator setup for local testing

## Important technical decisions
- The protocol uses a health factor model to enforce minimum collateral ratios.
- The system follows a strong overcollateralization principle to protect the stablecoin peg.
- Custom errors are used to make failures explicit and easier to reason about.
- CEI (Checks-Effects-Interactions) is used around key state changes to reduce unsafe ordering bugs.
- Chainlink price feeds are used to convert collateral into USD value for risk checks.
- The stablecoin contract is intentionally limited so that the engine is the main governance and accounting layer.

## Key features
- Collateral-backed minting of DSC
- Price-based collateral valuation using Chainlink or mocks
- Deposit and redeem flow for supported collateral assets
- Minting restrictions based on user health factor
- Liquidation logic for undercollateralized positions
- Network-aware deployment configuration for local or Sepolia environments
- Unit tests to verify protocol behavior under edge conditions

## Screenshots
No screenshots are included in the repository at this stage.

## Live demo
No live deployment is included in the repository.

## Challenges and solutions
The hardest part of this project is maintaining a sustainable collateral ratio in a volatile environment. The solution is to enforce strong liquidation and health-factor checks, and use price feeds as the source of truth for collateral value.

Another challenge is keeping the protocol minimal while still being safe and testable. That was solved with separated concerns: the token contract handles minting and burns, while the engine handles protocol rules and user accounting.

## Setup instructions
```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone
git clone https://github.com/Hayotunday/foundry-defi-stablecoin.git
cd foundry-defi-stablecoin

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Optional
forge fmt
forge snapshot
```

## What makes the project technically interesting
This project is interesting because it models a real DeFi primitive: an algorithmic-but-collateralized stablecoin system. It blends ERC20 mechanics, price oracle data, capital efficiency, liquidation economics, and secure contract design into one protocol. It is also a strong example of how to express financial invariants directly in Solidity.

## Project status
This repo is a smart-contract prototype and learning project focused on stablecoin protocol design. It is not a production deployment, but it captures strong DeFi engineering principles in a testable Foundry project.

## License
Follow the repository license file for the exact license terms if needed.
