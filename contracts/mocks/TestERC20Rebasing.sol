// SPDX-License-Identifier: MIT

import { ERC20Rebasing } from "../ERC20Rebasing.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestERC20Rebasing is ERC20Rebasing {
    constructor() ERC20("Test", "TEST") {}

    function rebase(int256 supplyDelta) external {
        _rebase(supplyDelta);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}