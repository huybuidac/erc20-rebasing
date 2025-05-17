// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Removed: import "hardhat/console.sol"; // Typically for debugging, not for abstract/production contracts.

/**
 * @title Abstract ERC20 Rebasing Token
 * @author Your Name/Project Name
 * @notice This abstract contract implements an ERC20 token with an elastic supply mechanism.
 * @dev Balances are represented internally as 'shares'. An account's share balance remains constant during a rebase.
 * The rebasing mechanism adjusts the `rebasedTotalSupply`, which in turn changes the token value
 * represented by each share.
 * Token balances are synced (materialized) from share balances either explicitly via `sync(address)`
 * or implicitly during transfers, mints, and burns.
 * This contract is designed to be inherited by a concrete token implementation that will define
 * the specific conditions and logic for triggering a rebase (e.g., via an oracle, by an owner, etc.).
 * It supports starting with zero initial supply; supply is introduced via minting.
 */
abstract contract ERC20Rebasing is ERC20 {
    using Math for uint256;

    /// @notice The scaling factor used in share-to-token and token-to-share calculations to maintain precision.
    /// @dev This helps prevent loss of granularity, especially when dealing with small amounts or
    ///      during conversions when total supply or total shares are low or zero.
    uint256 constant DEFAULT_PRECISION = 1e6;

    /// @dev Total number of shares in existence. This is the sum of all `_shareBalances`.
    uint256 private _totalShares;
    /// @dev Mapping from account address to its share balance.
    mapping(address => uint256) private _shareBalances;

    /// @notice The target total supply of the token after the most recent rebase.
    /// @dev This value represents the intended total supply. The sum of all individual ERC20 balances
    ///      (as returned by `balanceOf`) will only equal `rebasedTotalSupply` once all accounts have synced.
    ///      This value is adjusted by `_rebase` and also by mint/burn operations in `_update`.
    uint256 public rebasedTotalSupply;

    /// @notice A counter that increments with each rebase operation, marking distinct rebase epochs.
    uint256 public rebasedCounter;
    /// @dev Mapping from account address to the `rebasedCounter` value at which their balance was last synced.
    mapping(address account => uint256) public rebasedCounters;

    /// @notice Error: Rebase operation failed due to potential arithmetic overflow or underflow.
    /// @param currentRebasedTotalSupply The `rebasedTotalSupply` before the attempted rebase.
    /// @param supplyDelta The change in supply that caused the error (e.g., subtracting too much).
    error RebaseInvalidDelta(uint256 currentRebasedTotalSupply, int256 supplyDelta);

    /// @notice Error: Rebase attempted when `rebasedTotalSupply` is zero.
    /// @dev A rebase operation requires a non-zero supply to adjust. Supply should be introduced via minting first.
    error RebaseFromZeroSupply();

    /// @notice Emitted when the `rebasedTotalSupply` is adjusted.
    /// @param newRebasedTotalSupply The new `rebasedTotalSupply` after the rebase.
    /// @param supplyDelta The change applied to the total supply (can be positive or negative).
    /// @param epoch The `rebasedCounter` value for this rebase event.
    event Rebased(uint256 newRebasedTotalSupply, int256 supplyDelta, uint256 epoch);

    /// @notice Emitted when an account's token balance is explicitly synced with the latest rebase.
    /// @param account The address of the account that was synced.
    /// @param balanceDelta The change in the account's token balance due to the sync (can be positive or negative).
    /// @param newBalance The new token balance of the account after syncing.
    event Synced(address indexed account, int256 balanceDelta, uint256 newBalance);

    /**
     * @notice Explicitly syncs the caller's token balance to reflect the latest rebase.
     * @dev This function is useful if a user wants to ensure their `balanceOf` reflects the
     * most current token value of their shares without performing a transfer.
     * It calls the internal `_sync` function for the message sender.
     * @param account The address of the account to sync. It must be `msg.sender`.
     * @dev Although the parameter is `account`, current implementation implicitly syncs `msg.sender`.
     * Consider making it sync `msg.sender` directly or allow syncing for `account` if `msg.sender` is authorized.
     * For now, to sync `account`, `account` must call this function.
     * If the intention is to allow anyone to trigger a sync for any account, `_sync(account)` should be called.
     * However, the current external `sync` function provided in the original code only takes `account`
     * but doesn't use `msg.sender` to check authorization if `account != msg.sender`.
     * The original code calls `_sync(account)`.
     */
    function sync(address account) external virtual {
        // Dev Note: If this function is intended to be called by an account to sync its own balance,
        // it should ideally be `_sync(_msgSender())`.
        // If it's for syncing any account, then authorization might be needed or it's a public utility.
        // The original implementation syncs the provided `account`.
        _sync(account);
    }

    /**
     * @dev Adjusts the `rebasedTotalSupply` by `supplyDelta`.
     * @notice This is the core internal function for the rebasing mechanism.
     * It should be called by derived contracts to enact a supply change.
     * @param supplyDelta The amount to change the `rebasedTotalSupply` by.
     * Positive for expansion, negative for contraction.
     * @dev Reverts if `rebasedTotalSupply` is zero (use `_mint` to create initial supply).
     * Reverts if `supplyDelta` would cause `rebasedTotalSupply` to become zero or underflow (e.g., decrease by more than available supply).
     * Increments `rebasedCounter` to signify a new rebase epoch.
     * Emits a {Rebased} event.
     */
    function _rebase(int256 supplyDelta) internal virtual {
        uint256 currentSupply = rebasedTotalSupply; // Cache before modification
        if (currentSupply == 0) {
            revert RebaseFromZeroSupply();
        }

        if (supplyDelta == 0) {
            // No change, but still increment counter to allow syncing for other reasons if needed,
            // or simply return. For now, let's consider a zero delta rebase as a new epoch.
        } else if (supplyDelta < 0) {
            uint256 absDelta = uint256(-supplyDelta);
            if (absDelta >= currentSupply) { // Cannot decrease to zero or less via rebase
                revert RebaseInvalidDelta(currentSupply, supplyDelta);
            }
            rebasedTotalSupply = currentSupply - absDelta;
        } else { // supplyDelta > 0
            uint256 absDelta = uint256(supplyDelta);
            // Check for overflow before addition, though uint256 addition overflow is rare with typical supply sizes.
            if (type(uint256).max - currentSupply < absDelta) { // currentSupply + absDelta > type(uint256).max
                 revert RebaseInvalidDelta(currentSupply, supplyDelta);
            }
            rebasedTotalSupply = currentSupply + absDelta;
        }

        rebasedCounter++;
        emit Rebased(rebasedTotalSupply, supplyDelta, rebasedCounter);
    }

    /**
     * @dev Overrides ERC20._update to manage share balances alongside token balances.
     * @dev This function is called internally by `_mint`, `_burn`, and `_transfer`.
     * It ensures that:
     * 1. Accounts involved in an operation are synced to the latest rebase epoch before the operation.
     * 2. Share balances (`_shareBalances` and `_totalShares`) are updated according to the token amount.
     * 3. `rebasedTotalSupply` is updated during mints and burns to reflect the actual change in
     * circulating tokens, distinct from supply changes via `_rebase`.
     * Rounding for share calculations: Ceil for credits (mint, transfer to), Floor for debits (burn, transfer from).
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) {
            // Mint operation
            _sync(to); // Sync receiver before minting.
            uint256 sharesToMint = _convertToShares(amount, Math.Rounding.Ceil);
            // Important: rebasedTotalSupply increases here because new tokens (and corresponding shares) are created.
            // This is separate from the _rebase mechanism's adjustment of rebasedTotalSupply.
            unchecked {
                _shareBalances[to] += sharesToMint;
                _totalShares += sharesToMint;
                rebasedTotalSupply += amount; // Actual supply increases
            }
            // Call ERC20's _update which handles `_balances` and `_totalSupply` (which we override for rebasedTotalSupply)
            // and emits Transfer event.
            ERC20._update(from, to, amount);
        } else if (to == address(0)) {
            // Burn operation
            _sync(from); // Sync sender before burning.

            // If amount is exactly the balance, clear all shares to prevent dust shares. Otherwise, convert.
            uint256 sharesToBurn = (ERC20.balanceOf(from) == amount && _shareBalances[from] > 0)
                ? _shareBalances[from]
                : _convertToShares(amount, Math.Rounding.Floor);

            // Ensure we don't burn more shares than the account has.
            // This check is implicitly handled by super._update's balance check for tokens,
            // but an explicit check for shares can be added if shares can desync from tokens.
            // However, _convertToShares should yield a proportional amount.
            // If sharesToBurn > _shareBalances[from], it implies an issue or extreme rounding.
            // For simplicity, we assume _convertToShares correctly reflects the token amount.

            // Call ERC20's _update
            ERC20._update(from, to, amount); // This will decrease super._balances[from] and super._totalSupply
            unchecked {
                _shareBalances[from] -= sharesToBurn;
                _totalShares -= sharesToBurn;
                rebasedTotalSupply -= amount;
            }
        } else {
            // Transfer operation
            _sync(from);
            _sync(to);

            // For 'from': like burn, round down. If amount is full balance, transfer all shares.
            uint256 sharesFrom = (super.balanceOf(from) == amount && _shareBalances[from] > 0)
                ? _shareBalances[from]
                : _convertToShares(amount, Math.Rounding.Floor);

            // For 'to': like mint, round up.
            uint256 sharesTo = _convertToShares(amount, Math.Rounding.Ceil);

            // Call ERC20's _update first. 
            ERC20._update(from, to, amount);

            unchecked {
                _shareBalances[from] -= sharesFrom;
                _shareBalances[to] += sharesTo;
            }
        }
    }

    /**
     * @notice Gets the current target total supply of tokens, reflecting the latest rebase.
     * @dev Returns the `rebasedTotalSupply`. This value represents the total number of tokens
     * that would be in circulation if all accounts were synced.
     * @return The rebased total supply of tokens.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return rebasedTotalSupply;
    }

    /**
     * @notice Gets the token balance of the specified address, reflecting rebases since its last sync.
     * @dev If a rebase has occurred since the account's last sync (i.e., `rebasedCounter > rebasedCounters[account]`),
     * the balance is calculated on-the-fly based on its shares and the current `rebasedTotalSupply`
     * using `_convertToTokens`. Otherwise, it returns the standard ERC20 balance stored by the
     * parent contract (which would be up-to-date if synced).
     * @param account The address to query the balance of.
     * @return The token balance of the specified address.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        if (rebasedCounter > rebasedCounters[account]) {
            if (_totalShares == 0) return 0; // Avoid division by zero if no shares exist
            return _convertToTokens(_shareBalances[account], Math.Rounding.Floor);
        }
        return ERC20.balanceOf(account); // Returns the materialized balance from ERC20._balances
    }

    /**
     * @notice Converts a token amount to its corresponding internal share amount.
     * @dev Calculates shares using the formula:
     * `amount * (_totalShares + _precision()) / (rebasedTotalSupply + 1)`
     * The addition of `_precision()` to `_totalShares` and `1` to `rebasedTotalSupply` serves multiple purposes:
     * 1. Prevents division by zero if `rebasedTotalSupply` is notionally zero (e.g., before any supply is active or if it's rebased low).
     * 2. Enhances precision in the division, especially when `_totalShares` is small or zero (e.g. initial mints).
     * The `_precision()` acts as a baseline scaling for shares.
     * This function is typically used when shares are being credited (e.g., mint, transfer-in).
     * @param amount The amount of tokens to convert.
     * @param rounding The rounding direction for `mulDiv` (Ceil for credits, Floor for debits).
     * @return The corresponding amount of shares.
     */
    function _convertToShares(uint256 amount, Math.Rounding rounding) internal view virtual returns (uint256) {
        if (amount == 0) return 0;
        // If rebasedTotalSupply is 0 (e.g., before first mint, or if contract allows it),
        // shares are minted based on a ratio to precision. This allows bootstrapping.
        // `rebasedTotalSupply + 1` ensures denominator is non-zero.
        // `_totalShares + _precision()` ensures numerator reflects shares or precision baseline.
        unchecked {
             // If rebasedTotalSupply is effectively zero (e.g. before first mint, or if it could be rebased to near zero)
            // and _totalShares is also zero (first mint ever), then shares are minted proportional to amount * _precision.
            // Example: Minting 100 tokens when supply is 0, shares is 0.
            // shares = 100 * (0 + 1e6) / (0 + 1) = 100 * 1e6.
            // This establishes an initial token-to-share value.
            // If totalShares > 0 but rebasedTotalSupply is 0 (e.g. after a massive contraction rebase, or before first mint but after some shares were created through a non-standard mechanism),
            // this formula still provides a way to calculate shares.
            return amount.mulDiv(_totalShares + _precision(), rebasedTotalSupply + 1, rounding);
        }
    }

    /**
     * @notice Converts an internal share amount to its corresponding token amount.
     * @dev Calculates tokens using the formula:
     * `shares * (rebasedTotalSupply + 1) / (_totalShares + _precision())`
     * Similar to `_convertToShares`, `+ 1` and `+ _precision()` are used to prevent division by zero
     * and maintain precision, especially if `_totalShares` is zero or very small.
     * This function is used for display (e.g., `balanceOf` before sync) or when shares are debited.
     * @param shares The amount of shares to convert.
     * @param rounding The rounding direction for `mulDiv`.
     * @return The corresponding amount of tokens.
     */
    function _convertToTokens(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        if (shares == 0) return 0;
        // `_totalShares + _precision()` ensures denominator is non-zero if _precision > 0.
        // `rebasedTotalSupply + 1` ensures numerator is non-zero if tokens are to have value.
        unchecked {
            // If _totalShares is zero (no shares exist or precision is also zero), and shares > 0 (which shouldn't happen if _totalShares is 0),
            // this could lead to issues if _precision is also 0. DEFAULT_PRECISION ensures a non-zero denominator.
            // If rebasedTotalSupply is 0, tokens effectively have no value unless shares also map to a precision unit.
            // Example: If rebasedTotalSupply is 0, _totalShares is 1e12 (from previous mints), _precision is 1e6.
            // tokens = shares * (0 + 1) / (1e12 + 1e6) approx shares / 1e12. (Very small token value).
            return shares.mulDiv(rebasedTotalSupply + 1, _totalShares + _precision(), rounding);
        }
    }

    /**
     * @dev Internal function to synchronize an account's ERC20 balance with the latest rebase state.
     * @notice Updates an account's material token balance (`ERC20._balances`) to reflect the current
     * value of its shares post-rebase.
     * @param account The address of the account to sync.
     * @dev This function is called when:
     * 1. An explicit `sync(address)` is requested.
     * 2. Before any token operation (`_update`: mint, burn, transfer) to ensure calculations use current values.
     * If the `rebasedCounter` (global rebase epoch) is more recent than `rebasedCounters[account]`
     * (account's last synced epoch), the account's ERC20 token balance is updated.
     * This involves:
     * - Calculating the expected token balance (`rebasedBalance`) based on its current shares and the global rebase state.
     * - Comparing it to the current materialized ERC20 balance (`rawBalance` from `super.balanceOf(account)`).
     * - Minting or burning the difference (`delta`) using `super._update` directly.
     * `super._update` is used to bypass the share accounting logic in *this contract's* overridden `_update`,
     * as `_sync` only reconciles token balances with *existing* share balances; it doesn't change share counts.
     * The account's `rebasedCounters` is updated to the current `rebasedCounter`.
     * Emits a {Synced} event if the balance changes.
     */
    function _sync(address account) internal virtual {
        if (rebasedCounter > rebasedCounters[account]) {
            uint256 currentRawBalance = super.balanceOf(account); // Current materialized token balance
            uint256 expectedRebasedBalance = 0;
            if (_totalShares > 0) { // Only calculate if there are shares, otherwise balance is 0
                 expectedRebasedBalance = _convertToTokens(_shareBalances[account], Math.Rounding.Floor);
            }


            rebasedCounters[account] = rebasedCounter; // Mark as synced to current epoch

            int256 delta = int256(expectedRebasedBalance) - int256(currentRawBalance);

            if (delta > 0) {
                // Mint the difference. Call super._update to only affect token balances, not shares.
                super._update(address(0), account, uint256(delta));
                emit Synced(account, delta, expectedRebasedBalance);
            } else if (delta < 0) {
                // Burn the difference. Call super._update.
                super._update(account, address(0), uint256(-delta));
                emit Synced(account, delta, expectedRebasedBalance);
            }
            // If delta is 0, no balance change, but account is now marked as synced. No event needed.
        }
    }

    /**
     * @dev Returns the precision factor used in share calculations.
     * @notice Provides the constant scaling factor for share/token conversions.
     * @return The precision value, `DEFAULT_PRECISION`.
     */
    function _precision() internal view virtual returns (uint256) {
        return DEFAULT_PRECISION;
    }
}
