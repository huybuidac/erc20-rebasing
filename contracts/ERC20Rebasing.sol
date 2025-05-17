/// SPDX-License-Identifier: MIT

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "hardhat/console.sol";

/**
 * @title ERC20 Rebasing Token
 * @dev This contract implements an ERC20 token with a rebasing mechanism.
 *      The token's total supply can be adjusted via the `_rebase` function.
 *      Individual balances are updated proportionally when they are synced,
 *      which happens automatically during transfers, mints, and burns, or manually via `sync`.
 *      Balances are internally represented in 'shares'. The conversion between shares and tokens
 *      depends on the `rebasedTotalSupply` and `totalShares`.
 *      This implementation overrides `_update` to manage share balances alongside token balances.
 */
abstract contract ERC20Rebasing is ERC20 {
    using Math for uint256;

    /// @notice The default precision factor used in share calculations to maintain granularity.
    uint256 constant DEFAULT_PRECISION = 1e6;

    uint256 private _totalShares;
    mapping(address => uint256) private _shareBalances;

    uint256 public rebasedTotalSupply;
    uint256 public rebasedCounter;
    mapping(address account => uint256) public rebasedCounters;

    /// @notice Error emitted when a rebase operation would result in an invalid total supply (e.g., underflow by subtracting too much).
    /// @param rebasedTotalSupply The current rebased total supply before the problematic rebase.
    /// @param supplyDelta The attempted change in supply that caused the error.
    error RebaseOverflow(uint256 rebasedTotalSupply, int256 supplyDelta);

    /// @notice Error emitted if a rebase operation is attempted when the `rebasedTotalSupply` is zero.
    error TotalSupplyZero();

    /// @notice Emitted when the total supply is rebased.
    /// @param rebasedTotalSupply The new total supply after the rebase.
    /// @param supplyDelta The change in supply that occurred during the rebase (can be positive or negative).
    event Rebased(uint256 rebasedTotalSupply, int256 supplyDelta);

    /// @notice Emitted when an account's balance is synced with the latest rebase, indicating a change in their token balance.
    /// @param account The address of the account that was synced.
    /// @param delta The change in the account's token balance due to the sync (can be positive or negative).
    event Synced(address indexed account, int256 delta);

    /**
     * @notice Syncs a single account's balance with the latest rebase state.
     * @dev If a rebase has occurred since the account's last sync (i.e., `rebasedCounter` > `rebasedCounters[account]`),
     *      its token balance is updated by minting or burning tokens to match the value of its shares
     *      at the current rebase rate.
     * @param account The address of the account to sync.
     */
    function sync(address account) external virtual {
        _sync(account);
    }

    /**
     * @dev Adjusts the `rebasedTotalSupply` by `supplyDelta` and increments `rebasedCounter`.
     *      This function is the core of the rebasing mechanism.
     *      It reverts if `rebasedTotalSupply` is zero or if `supplyDelta` would cause an underflow.
     * @param supplyDelta The change in total supply. Can be positive (expansion) or negative (contraction).
     */
    function _rebase(int256 supplyDelta) internal virtual {
        if (rebasedTotalSupply == 0) {
            revert TotalSupplyZero();
        }
        if (supplyDelta < 0 && uint256(-supplyDelta) >= rebasedTotalSupply) {
            // should not decrease to zero or less
            revert RebaseOverflow(rebasedTotalSupply, supplyDelta);
        }

        if (supplyDelta > 0) {
            rebasedTotalSupply += uint256(supplyDelta);
        } else {
            rebasedTotalSupply -= uint256(-supplyDelta);
        }

        emit Rebased(rebasedTotalSupply, supplyDelta);

        rebasedCounter++;
    }

    /**
     * @dev Overrides ERC20._update to manage share balances alongside token balances.
     *      This function is called internally by `_mint`, `_burn`, and `_transfer`.
     *      It ensures that accounts are synced before their balances change and that
     *      share balances are updated consistently with token operations.
     * @param from The address from which tokens are being transferred (address(0) for mint).
     * @param to The address to which tokens are being transferred (address(0) for burn).
     * @param amount The amount of tokens being transferred, minted, or burned.
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) {
            // Mint operation
            _sync(to);
            uint256 share = _convertToShares(amount, Math.Rounding.Ceil);
            unchecked {
                _shareBalances[to] += share;
                _totalShares += share;
                rebasedTotalSupply += amount;
            }
            super._update(from, to, amount);
        } else if (to == address(0)) {
            // Burn operation
            _sync(from);
            
            // if amount is exactly the balance, clear shareBalances[from]
            uint256 share = super.balanceOf(from) == amount ? _shareBalances[from] : _convertToShares(amount, Math.Rounding.Floor);
            // amount overflow check on super._update
            super._update(from, to, amount);
            unchecked {
                _shareBalances[from] -= share;
                _totalShares -= share;
                rebasedTotalSupply -= amount;
            }
        } else {
            // transfer
            _sync(from);
            _sync(to);

            // like burn, round down. If amount is exactly the balance, clear shareBalances[from]
            uint256 shareFrom = super.balanceOf(from) == amount ? _shareBalances[from] : _convertToShares(amount, Math.Rounding.Floor);
            // like mint, should round up
            uint256 shareTo = _convertToShares(amount, Math.Rounding.Ceil);

            // amount overflow check on super._update
            super._update(from, to, amount);

            unchecked {
                _shareBalances[from] -= shareFrom;
                _shareBalances[to] += shareTo;
            }
        }
    }

    /**
     * @notice Gets the total supply of tokens.
     * @dev Returns the `rebasedTotalSupply`, which reflects the supply after the latest rebase.
     * @return The total supply of tokens.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return rebasedTotalSupply;
    }

    /**
     * @notice Gets the balance of the specified address.
     * @dev If a rebase has occurred since the account's last sync (`rebasedCounter` > `rebasedCounters[account]`),
     *      the balance is calculated based on its shares and the current rebased total supply using `_convertToTokens`.
     *      Otherwise, it returns the standard ERC20 balance stored by the parent contract.
     * @param account The address to query the balance of.
     * @return The balance of the specified address.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        if (rebasedCounter > rebasedCounters[account]) {
            return _convertToTokens(_shareBalances[account], Math.Rounding.Floor);
        }
        return super.balanceOf(account);
    }

    /**
     * @notice Converts a token amount to its corresponding share amount.
     * @dev Calculates shares using the formula: `amount * (totalShares + _precision()) / (rebasedTotalSupply + 1)`.
     *      Adding `_precision()` to `totalShares` and `1` to `rebasedTotalSupply` helps prevent division by zero
     *      and maintain precision, especially when total supply or total shares are small or zero.
     * @param amount The amount of tokens to convert.
     * @param rounding The rounding direction for `mulDiv`.
     * @return The corresponding amount of shares.
     */
    function _convertToShares(uint256 amount, Math.Rounding rounding) public view virtual returns (uint256) {
        unchecked {
            return amount.mulDiv(_totalShares + _precision(), rebasedTotalSupply + 1, rounding);
        }
    }

    /**
     * @notice Converts a share amount to its corresponding token amount.
     * @dev Calculates tokens using the formula: `shares * (rebasedTotalSupply + 1) / (totalShares + _precision())`.
     *      Adding `1` to `rebasedTotalSupply` and `_precision()` to `totalShares` helps prevent division by zero
     *      and maintain precision.
     * @param shares The amount of shares to convert.
     * @param rounding The rounding direction for `mulDiv`.
     * @return The corresponding amount of tokens.
     */
    function _convertToTokens(uint256 shares, Math.Rounding rounding) public view virtual returns (uint256) {
        unchecked {
            return shares.mulDiv(rebasedTotalSupply + 1, _totalShares + _precision(), rounding);
        }
    }

    /**
     * @dev Internal function to sync an account's balance with the latest rebase state.
     *      If the `rebasedCounter` is more recent than `rebasedCounters[account]`,
     *      the account's ERC20 token balance is updated to reflect the rebased value of its shares.
     *      This involves calculating the expected token balance (`rebasedBalance`) and comparing it
     *      to the current raw ERC20 balance (`rawBalance`). The difference (`delta`) is then
     *      minted (if `delta` > 0) or burned (if `delta` < 0) using `super._update`.
     *      The account's `rebasedCounters` is updated, and a `Synced` event is emitted.
     * @param account The address of the account to sync.
     */
    function _sync(address account) internal virtual {
        if (rebasedCounter > rebasedCounters[account]) {
            rebasedCounters[account] = rebasedCounter;

            uint256 rebasedBalance = _convertToTokens(_shareBalances[account], Math.Rounding.Floor);
            uint256 rawBalance = super.balanceOf(account);

            int256 delta = int256(rebasedBalance) - int256(rawBalance);

            if (delta > 0) {
                // We call super._update directly to bypass our overridden _update's share logic during sync,
                // as we are only adjusting the token balance to match the share value.
                super._update(address(0), account, uint256(delta));
                emit Synced(account, delta);
            } else if (delta < 0) {
                super._update(account, address(0), uint256(-delta));
                emit Synced(account, delta);
            }
        }
    }

    /**
     * @dev Returns the precision factor used in share calculations.
     * @return The precision value, `DEFAULT_PRECISION`.
     */
    function _precision() internal view virtual returns (uint256) {
        return DEFAULT_PRECISION;
    }
}

