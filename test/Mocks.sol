// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSeaport {
    event OrderFulfilled();
    
    function fulfillBasicOrder_efficient_6GL6yc(bytes calldata /* parameters */) external payable returns (bool) {
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
        
        // Return 1 wei of ETH for 1 wei of Token, for simplicity
        uint256 amountOut = amountIn;
        (bool success, ) = msg.sender.call{value: amountOut}("");
        require(success, "ETH transfer failed");
        return amountOut;
    }
    
    receive() external payable {}
}
