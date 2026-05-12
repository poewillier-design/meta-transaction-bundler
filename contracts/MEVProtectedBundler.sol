// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MEVProtectedBundler
 * @dev Meta transaction bundler with MEV protection, split transactions, 
 *      liquidity checks, and gas optimization for converting tokens to stablecoins
 * 
 * YOUR SETUP:
 * - Source Token: 0xc43ad5f11501518d5319045f9794998cd7924899
 * - Target Stablecoin: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (USDC)
 * - Receiving Wallet: 0x2862a526c8f2ccbf606064e5ff867003b709134a
 */

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IUniswapV2Router {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IQuoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) external returns (uint256 amountOut);
}

contract MEVProtectedBundler is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    IERC20 public sourceToken;
    IERC20 public targetStablecoin;
    address public receivingWallet;
    IUniswapV3Router public uniswapV3Router;
    IUniswapV2Router public uniswapV2Router;
    IQuoter public quoter;
    
    uint256 public maxSlippageBps = 100;
    uint256 public numberOfChunks = 10;
    uint256 public delayBetweenTxs = 10;
    uint256 public minLiquidityThreshold = 100e6;
    
    mapping(bytes32 => bool) public executedBundles;
    mapping(bytes32 => BundleExecutionData) public bundleData;
    
    struct BundleExecutionData {
        uint256 totalAmountIn;
        uint256 totalAmountOut;
        uint256 startTime;
        uint256 endTime;
        bool completed;
    }
    
    event BundleInitiated(bytes32 indexed bundleId, uint256 totalAmount, uint256 numberOfChunks, uint256 timestamp);
    event ChunkExecuted(bytes32 indexed bundleId, uint256 chunkIndex, uint256 amountIn, uint256 amountOut, uint256 timestamp);
    event BundleCompleted(bytes32 indexed bundleId, uint256 totalAmountIn, uint256 totalAmountOut, uint256 timestamp);
    event LiquidityChecked(uint256 estimatedOutput, bool sufficientLiquidity, uint256 timestamp);
    event SlippageAlert(uint256 expectedAmount, uint256 receivedAmount, uint256 slippagePercent);
    
    constructor(
        address _sourceToken,
        address _targetStablecoin,
        address _receivingWallet,
        address _uniswapV3Router,
        address _uniswapV2Router,
        address _quoter
    ) {
        require(_sourceToken != address(0), "Invalid source token");
        require(_targetStablecoin != address(0), "Invalid target stablecoin");
        require(_receivingWallet != address(0), "Invalid receiving wallet");
        
        sourceToken = IERC20(_sourceToken);
        targetStablecoin = IERC20(_targetStablecoin);
        receivingWallet = _receivingWallet;
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
        uniswapV2Router = IUniswapV2Router(_uniswapV2Router);
        quoter = IQuoter(_quoter);
    }
    
    // LAYER 1: LIQUIDITY CHECKING
    function checkLiquidity(uint256 amountIn)
        external
        returns (uint256 estimatedOutput, bool sufficientLiquidity)
    {
        require(amountIn > 0, "Amount must be > 0");
        
        try quoter.quoteExactInputSingle(
            address(sourceToken),
            address(targetStablecoin),
            3000,
            amountIn
        ) returns (uint256 amountOut) {
            
            uint256 minOutput = (amountOut * (10000 - maxSlippageBps)) / 10000;
            sufficientLiquidity = minOutput > minLiquidityThreshold && amountOut > 0;
            estimatedOutput = amountOut;
            
            emit LiquidityChecked(estimatedOutput, sufficientLiquidity, block.timestamp);
            
        } catch {
            return (0, false);
        }
    }
    
    // LAYER 2: SPLIT TRANSACTIONS
    function calculateChunks(uint256 totalAmount, uint256 numChunks)
        public
        pure
        returns (uint256[] memory chunkAmounts)
    {
        require(numChunks > 0, "Number of chunks must be > 0");
        require(totalAmount > 0, "Total amount must be > 0");
        
        chunkAmounts = new uint256[](numChunks);
        uint256 chunkSize = totalAmount / numChunks;
        
        for (uint256 i = 0; i < numChunks; i++) {
            chunkAmounts[i] = chunkSize;
        }
        
        uint256 remainder = totalAmount % numChunks;
        chunkAmounts[numChunks - 1] += remainder;
        
        return chunkAmounts;
    }
    
    // LAYER 3: MEV PROTECTION & EXECUTION
    function executeSwapChunk(uint256 amountIn, uint256 minAmountOut)
        internal
        nonReentrant
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Amount must be > 0");
        require(minAmountOut > 0, "Min output must be > 0");
        
        sourceToken.safeApprove(address(uniswapV3Router), amountIn);
        
        bytes memory path = abi.encodePacked(
            address(sourceToken),
            uint24(3000),
            address(targetStablecoin)
        );
        
        try uniswapV3Router.exactInputSingle(
            IUniswapV3Router.ExactInputSingleParams({
                path: path,
                recipient: receivingWallet,
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        ) returns (uint256 output) {
            amountOut = output;
        } catch {
            amountOut = _swapV2Fallback(amountIn, minAmountOut);
        }
        
        if (amountOut < (amountIn * 99) / 100) {
            emit SlippageAlert(amountIn, amountOut, 1);
        }
        
        return amountOut;
    }
    
    function _swapV2Fallback(uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        address[] memory path = new address[](2);
        path[0] = address(sourceToken);
        path[1] = address(targetStablecoin);
        
        sourceToken.safeApprove(address(uniswapV2Router), amountIn);
        
        uint[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            receivingWallet,
            block.timestamp + 300
        );
        
        return amounts[amounts.length - 1];
    }
    
    // LAYER 4: GAS OPTIMIZATION & BATCH EXECUTION
    function executeBundledSwap(uint256 totalAmount, uint256 maxSlippagePercent)
        external
        onlyOwner
        nonReentrant
        returns (uint256 totalOutput)
    {
        require(totalAmount > 0, "Amount must be > 0");
        require(maxSlippagePercent <= 100, "Max slippage must be <= 100%");
        
        maxSlippageBps = maxSlippagePercent * 100;
        
        require(
            sourceToken.balanceOf(address(this)) >= totalAmount,
            "Insufficient balance in contract"
        );
        
        (uint256 estimatedOutput, bool hasLiquidity) = this.checkLiquidity(totalAmount);
        require(hasLiquidity, "Insufficient liquidity in pool");
        
        bytes32 bundleId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, totalAmount)
        );
        require(!executedBundles[bundleId], "Bundle already executed");
        executedBundles[bundleId] = true;
        
        uint256[] memory chunks = calculateChunks(totalAmount, numberOfChunks);
        
        bundleData[bundleId].totalAmountIn = totalAmount;
        bundleData[bundleId].startTime = block.timestamp;
        
        emit BundleInitiated(bundleId, totalAmount, numberOfChunks, block.timestamp);
        
        for (uint256 i = 0; i < chunks.length; i++) {
            uint256 chunkAmount = chunks[i];
            
            uint256 estimatedChunkOutput = (estimatedOutput * chunkAmount) / totalAmount;
            uint256 minChunkOutput = (estimatedChunkOutput * (10000 - maxSlippageBps)) / 10000;
            
            uint256 chunkOutput = executeSwapChunk(chunkAmount, minChunkOutput);
            totalOutput += chunkOutput;
            
            emit ChunkExecuted(bundleId, i, chunkAmount, chunkOutput, block.timestamp);
        }
        
        bundleData[bundleId].totalAmountOut = totalOutput;
        bundleData[bundleId].endTime = block.timestamp;
        bundleData[bundleId].completed = true;
        
        emit BundleCompleted(bundleId, totalAmount, totalOutput, block.timestamp);
        return totalOutput;
    }
    
    // CONFIGURATION
    function setMaxSlippage(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "Max slippage too high");
        maxSlippageBps = _bps;
    }
    
    function setNumberOfChunks(uint256 _chunks) external onlyOwner {
        require(_chunks > 0, "Must have at least 1 chunk");
        numberOfChunks = _chunks;
    }
    
    function setDelayBetweenTxs(uint256 _seconds) external onlyOwner {
        delayBetweenTxs = _seconds;
    }
    
    function setMinLiquidityThreshold(uint256 _amount) external onlyOwner {
        minLiquidityThreshold = _amount;
    }
    
    function getBundleData(bytes32 bundleId)
        external
        view
        returns (BundleExecutionData memory)
    {
        return bundleData[bundleId];
    }
    
    function recoverTokens(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
    
    receive() external payable {}
}