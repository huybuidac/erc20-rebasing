# ERC20Rebasing Token: A Flexible and Inflation-Resistant Implementation

## Overview

`ERC20Rebasing.sol` is an abstract Solidity smart contract that provides a foundation for creating ERC20-compliant tokens with an elastic supply, commonly known as rebasing tokens. In this system, an account's underlying "share" balance remains constant during a rebase event. Instead, the overall target total supply of the token (`rebasedTotalSupply`) is adjusted. This change in `rebasedTotalSupply` proportionally alters the amount of tokens represented by each share.

Token balances, as perceived by users and other contracts via `balanceOf()`, are dynamically calculated based on their shares or explicitly synchronized. Synchronization (syncing) happens automatically during core token operations (transfer, mint, burn) or can be manually triggered.

This contract is designed to be inherited by a concrete token implementation, which will define the specific logic and conditions for triggering a rebase (e.g., based on oracle price feeds, administrative actions, or other on-chain/off-chain events).

## The Challenge with Rebasing Tokens

Developing rebasing tokens presents unique challenges:
* **Lack of Standardization:** Unlike standard ERC20s, there isn't a universally adopted EIP specifically for rebasing mechanics, leading to varied implementations.
* **Complexity in Accounting:** Ensuring that proportional ownership is maintained accurately through rebases requires careful internal accounting.
* **Potential for Exploits:** Incorrect handling of supply adjustments, rounding, or edge cases (like zero supply) can lead to vulnerabilities.
* **Existing Solution Limitations:** Some existing rebasing token contracts may impose constraints, such as requiring a non-zero initial supply at deployment, which might not suit all use cases. For instance, the Ampleforth (UFragments) contract initializes with a defined supply.

## Our Approach: `ERC20Rebasing.sol`

This contract offers a robust, flexible, and security-conscious approach to rebasing tokens by focusing on:

### Core Mechanism: Shares and Proportional Adjustment

1.  **Internal Shares:** Each token holder possesses an internal balance of "shares" (`_shareBalances`). This share amount does *not* change during a rebase.
2.  **Rebased Total Supply (`rebasedTotalSupply`):** This state variable represents the target total supply of the token. The core rebasing logic, implemented in the derived contract, will call the internal `_rebase(int256 supplyDelta)` function to modify this value.
3.  **Token Value per Share:** The number of actual tokens a user "owns" is a function of their shares relative to the total shares (`_totalShares`) and the current `rebasedTotalSupply`.
    * `balanceOf(account)` (simplified) ≈ `(_shareBalances[account] * rebasedTotalSupply) / _totalShares`
4.  **Synchronization (`sync`):** An account's ERC20 token balance (stored in `ERC20._balances`) is updated to reflect the current value of their shares during transfers, mints, burns, or via an explicit `sync(address)` call.

### Key Features

* **Effective & Flexible Rebasing Engine:**
    * The internal `_rebase(int256 supplyDelta)` function allows derived contracts to implement custom rebase triggers and logic.
    * Supports both positive (expansionary) and negative (contractionary) rebases.
    * A `rebasedCounter` tracks rebase epochs, ensuring accounts sync to the correct state.

* **Zero Initial Supply Friendly:**
    * The contract can be deployed without any initial token supply. `rebasedTotalSupply` and `_totalShares` can start at zero.
    * The first mint operation will correctly initialize `rebasedTotalSupply` and `_totalShares`.
    * Conversion functions (`_convertToShares`, `_convertToTokens`) are designed to gracefully handle zero or low supply/share scenarios by incorporating a `DEFAULT_PRECISION` factor and adding 1 to denominators in divisions. This prevents division-by-zero errors and ensures calculations remain meaningful even when bootstrapping supply from zero.

* **Inflation Attack Resistance & Fairness:**
    * **Proportionality:** Since rebases adjust `rebasedTotalSupply` globally, the token value of every share changes proportionally. This ensures that no single user is unfairly diluted or benefited outside the intended rebase logic. An individual's *share* count is invariant to rebases.
    * **Precision Handling:** The use of `DEFAULT_PRECISION` (e.g., `1e6`) in share/token conversion formulas mitigates rounding errors that could be exploited, especially with small amounts or frequent rebases. It scales values before division to maintain granularity.
    * **Consistent Accounting:** The overridden `_update` function meticulously manages `_shareBalances`, `_totalShares`, and `rebasedTotalSupply` during mints, burns, and transfers, keeping internal and external representations consistent.
    * **Distinct from Vault Attacks:** While not an ERC4626 vault, the principle of using a stable internal unit (shares) whose relationship to the external unit (tokens) is globally adjusted provides inherent resistance to dilution attacks that might target direct manipulation of balances or share prices. The rebase mechanism is a controlled process.

* **On-Demand (Lazy) Syncing:**
    * Token balances are only materialized from shares when necessary (transfers, mints, burns) or when `sync(address)` is explicitly called. This can be more gas-efficient than updating all balances globally with each rebase, especially with many holders.

* **Clear Eventing:**
    * `Rebased(uint256 newRebasedTotalSupply, int256 supplyDelta, uint256 epoch)`: Signals a change in the token's target total supply.
    * `Synced(address indexed account, int256 balanceDelta, uint256 newBalance)`: Signals an account's token balance has been updated to the latest rebase.

* **Robust Error Handling:**
    * Custom errors like `RebaseInvalidDelta` and `RebaseFromZeroSupply` provide clear reasons for failed rebase operations.

* **OpenZeppelin Foundation:**
    * Inherits from OpenZeppelin's extensively audited `ERC20.sol`, providing a secure and standard-compliant base.

### How It Works (Simplified Technical Detail)

* **State Variables:**
    * `_totalShares`: Sum of all shares held by all users.
    * `_shareBalances[account]`: Number of shares an individual account holds.
    * `rebasedTotalSupply`: The current "target" total supply of the actual token.
    * `rebasedCounter`: Tracks the current rebase epoch.
    * `rebasedCounters[account]`: Tracks the epoch to which an account's balance was last synced.
* **Key Functions:**
    * `_rebase(int256 supplyDelta)`: (Internal) Called by the derived contract to change `rebasedTotalSupply`.
    * `_sync(address account)`: (Internal) Updates an account's actual ERC20 balance in `ERC20._balances` to match its share value after a rebase.
    * `balanceOf(address account)`: Returns the synced ERC20 balance if up-to-date, otherwise calculates it based on current shares and `rebasedTotalSupply`.
    * `_convertToShares()` / `_convertToTokens()`: Internal utility functions for converting between token amounts and share amounts, incorporating precision logic.
    * `_update()`: (Override) Manages share and `rebasedTotalSupply` accounting during mints, burns, and transfers, ensuring accounts are synced.

## Getting Started (For Developers)

To use `ERC20Rebasing.sol` to create your own rebasing token:

1.  **Inherit:** Create your new contract and inherit from `ERC20Rebasing`.
    ```solidity
    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.20;

    import {ERC20Rebasing} from "./ERC20Rebasing.sol"; // Adjust path as needed
    import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // Example for access control

    contract MyRebasingToken is ERC20Rebasing, Ownable {
        constructor(string memory name, string memory symbol, address initialOwner)
            ERC20(name, symbol)
            Ownable(initialOwner)
        {
            // Initial minting can be done here if desired, e.g.:
            // _mint(initialOwner, 1000 * (10**uint256(decimals())));
            // If no initial mint, rebasedTotalSupply starts at 0.
            // The first call to _mint will initialize rebasedTotalSupply and _totalShares.
        }

        // Example: Public function to trigger a rebase, callable only by owner
        function triggerRebase(int256 supplyDelta) external onlyOwner {
            _rebase(supplyDelta);
        }

        // Your custom logic for determining when and how to rebase goes here.
        // This could involve oracles, timers, governance decisions, etc.
    }
    ```

2.  **Constructor:** Implement a constructor for your token (e.g., setting name, symbol, and potentially an owner for rebase control). You can mint initial tokens here or allow the supply to start at zero.

3.  **Implement Rebase Logic:** The most crucial part is to define *how and when* the `_rebase(int256 supplyDelta)` function is called. This logic will reside in your derived contract.
    * This could be an owner-restricted function.
    * It could be triggered by an oracle reporting an external value (e.g., price target).
    * It could be time-based.

4.  **Access Control:** Secure the mechanism that calls `_rebase()`. Use `Ownable`, role-based access control, or other appropriate patterns.

5.  **Deployment & Testing:** Deploy your contract and test the rebasing mechanics thoroughly, including edge cases like zero supply, large supply changes, and interactions with DeFi protocols.

## Comparison with Ampleforth (UFragments)

* **Initial Supply:** The Ampleforth `UFragments.sol` contract, as per its public implementation, typically initializes with a defined `INITIAL_FRAGMENTS_SUPPLY` in its constructor. `ERC20Rebasing.sol` is designed for greater flexibility, explicitly supporting deployment with zero initial supply. Supply is introduced via standard minting operations, which correctly set up the initial share and token relationships.
* **Modularity:** `ERC20Rebasing.sol` is an abstract contract, clearly separating the core rebasing share mechanics from the specific trigger logic, which must be implemented by the inheriting contract.

## Security Considerations for Implementers

* **Rebase Trigger Security:** The primary security responsibility for implementers is the logic that calls `_rebase()`. This mechanism *must* be secure and operate as intended. Flaws here could lead to unintended supply manipulations.
* **Oracle Risks:** If using oracles to determine `supplyDelta`, ensure the oracle is reliable and resistant to manipulation.
* **Rounding and Precision:** While `DEFAULT_PRECISION` and careful rounding (Ceil for credits, Floor for debits) are used to minimize issues, extreme scenarios (e.g., tokens with vastly different decimal counts than typical, or extremely frequent tiny rebases) should be tested. The current `DEFAULT_PRECISION = 1e6` is a general-purpose value.
* **Gas Costs:** While lazy syncing is generally efficient, be mindful of the gas costs of `_sync` operations, especially if many accounts interact frequently immediately after a rebase.
* **Composability:** When integrating with other DeFi protocols, thoroughly test how they handle rebasing tokens. Some protocols may not be designed for tokens whose `balanceOf()` can change without a direct transfer. Explicitly syncing before interaction might be necessary.

## License

This contract is licensed under the MIT License (same as the SPDX-License-Identifier in the file).
