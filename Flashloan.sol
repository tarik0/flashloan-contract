pragma solidity >=0.6.6 <0.8.0;

// SPDX-License-Identifier: Unlicensed

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IERC20.sol";
import "@uniswap/v2-periphery/contracts/libraries/UniswapV2Library.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract FlashLoan {
    using SafeMath for uint256;
    
    address private immutable _owner;
    address public  immutable _wbnbAddress;
    
    uint private _deadline = 3 minutes;
    
    IUniswapV2Router02 public _currentTargetRouter;
    
    IUniswapV2Router02 public _pcsRouter;
    IUniswapV2Factory  public _pcsFactory;
    
    /**
     * Construct the contract.
     */
    constructor(address pcsRouterAddress, address targetRouterAddress) public {
        _owner = msg.sender;
        
        _currentTargetRouter = IUniswapV2Router02(targetRouterAddress);
        _pcsRouter           = IUniswapV2Router02(pcsRouterAddress);
        
        _wbnbAddress         = _pcsRouter.WETH();
        _pcsFactory          = IUniswapV2Factory(_pcsRouter.factory());
    } 
    
    /**
     * Set target router to swap tokens.
     */
    function setTargetRouter(address routerAddress) public {
        require(msg.sender == _owner);
        _currentTargetRouter = IUniswapV2Router02(routerAddress);
    }
    
    /**
     * Borrow token from PancakeSwap.
     */
    function borrow(address token0, address token1, uint256 amount0, uint256 amount1) external {
        address pairAddress = _pcsFactory.getPair(token0, token1);
        require(pairAddress != address(0), "Pair does not exist.");
        
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "Liquidity does not exist for that pair.");
        
        pair.swap(amount0, amount1, address(this), bytes("not empty"));
    }
    
    /**
     * This function gets triggered by PancakeSwap itself after borrow.
     */
    function pancakeCall(address _sender, uint _amount0, uint _amount1, bytes calldata _data) external {
        address[] memory path = new address[](2);
        uint amountToken = _amount0 == 0 ? _amount1 : _amount0;
        
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();
        
        require(msg.sender == UniswapV2Library.pairFor(address(_pcsFactory), token0, token1));
        require(_amount0 == 0 || _amount1 == 0);
        
        // if _amount0 is zero sell token1 for token0
        // else sell token0 for token1 as a result
        path[0] = _amount0 == 0 ? token1 : token0;
        path[1] = _amount0 == 0 ? token0 : token1;
        
        // IERC20 token that we will sell for otherToken
        IERC20 token = IERC20(_amount0 == 0 ? token1 : token0);
        token.approve(address(_currentTargetRouter), amountToken);

        // calculate the amount of token how much input token should be reimbursed
        uint amountRequired = UniswapV2Library.getAmountsIn(
            address(_pcsFactory),
            amountToken,
            path
        )[0];

        // swap token and obtain equivalent otherToken amountRequired as a result
        uint amountReceived = _currentTargetRouter.swapExactTokensForTokens(
            amountToken,
            amountRequired,
            path,
            msg.sender,
            _deadline
        )[1];
    
        // fail if we didn't get enough tokens
        if (amountReceived > amountRequired) {
            token.transfer(msg.sender, amountToken);
            require(amountReceived > amountRequired, "Router didn't give enough tokens.");
        }
        
        IERC20 otherToken = IERC20(_amount0 == 0 ? token0 : token1);
        otherToken.transfer(msg.sender, amountRequired);
        otherToken.transfer(_owner, amountReceived.sub(amountRequired));
    }
}
