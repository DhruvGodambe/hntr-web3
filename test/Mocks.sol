// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev 6-decimal mock matching mainnet USDT/USDC pricing assumptions.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor() ERC20("Mock USDT", "USDT") {
        _decimals = 6;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes a fixed fee (in basis points) on every transfer/transferFrom.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps; // e.g. 10 = 0.1%

    constructor(uint256 _feeBps) ERC20("Fee USDT", "fUSDT") {
        feeBps = _feeBps;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sendAmount = amount - fee;
        if (fee > 0) {
            _transfer(msg.sender, address(this), fee);
        }
        _transfer(msg.sender, to, sendAmount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 sendAmount = amount - fee;
        if (fee > 0) {
            _transfer(from, address(this), fee);
        }
        _transfer(from, to, sendAmount);
        return true;
    }
}

contract MockSeaport {
    event OrderFulfilled();

    function fulfillBasicOrder_efficient_6GL6yc(bytes calldata /* parameters */ ) external payable returns (bool) {
        emit OrderFulfilled();
        return true;
    }
}

contract MockSwapRouter {
    using SafeERC20 for IERC20;
    IERC20 public paymentToken;

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
    }

    function swapTokensForETH(uint256 amountIn) external returns (uint256) {
        paymentToken.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn;
        (bool success,) = msg.sender.call{value: amountOut}("");
        require(success, "ETH transfer failed");
        return amountOut;
    }

    receive() external payable {}
}
