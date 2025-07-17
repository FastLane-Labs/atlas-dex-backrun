// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { IUniswapV2Pair, IUniswapV3Pool, IUniswapV3Factory} from "./interfaces/IUniswap.sol";
import { SafeTransferLib, ERC20 } from "solmate/utils/SafeTransferLib.sol";
import { IAtlas } from "@atlas/interfaces/IAtlas.sol";
import { IShMonad } from "./interfaces/IShMonad.sol";
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external payable;
    function balanceOf(address account) external view returns (uint256);
}
import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "forge-std/console.sol";

// Monadex V1 related structs
struct BubbleV1TypesFraction {
    uint256 numerator;
    uint256 denominator;
}

struct BubbleV1TypesHookConfig {
    bool hookBeforeCall;
    bool hookAfterCall;
}

struct BubbleV1TypesSwapParams {
    uint256 amountAOut;
    uint256 amountBOut;
    address receiver;
    BubbleV1TypesHookConfig hookConfig;
    bytes data;
}

// Monadex V1 Pool Interface
interface IMonadexV1Pair {
    function getReserves() external view returns (uint256, uint256);
    function getPoolTokens() external view returns (address, address);
    function isPoolToken(address _token) external view returns (bool);
    function getPoolFee() external view returns (BubbleV1TypesFraction memory);
    function swap(BubbleV1TypesSwapParams calldata params) external;
}

enum DexType {
    Null,
    UniswapV2,
    UniswapV3,
    PancakeV3,
    MonadexV1
}

struct Swap {
    DexType dexType;
    address poolAddr;
    address tokenIn;
    address tokenOut;
}

// ----------------------------------------------------------------------------
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// ----------------------------------------------------------------------------

contract BoomerSwapSolver is SolverBase, ReentrancyGuard {
    IShMonad shmonad;
    constructor(
        address _weth,
        address _atlas,
        address _shmonad
    ) SolverBase(_weth, _atlas, msg.sender) {
        shmonad = IShMonad(_shmonad);
    }

    function execute(
        Swap[] calldata swapPath,
        uint256 amountIn,
        uint256 bidAmount,
        uint256 boostYieldAmount
    ) external payable nonReentrant returns (uint256) {
        uint256 amount = amountIn;
        address lastToken = swapPath[swapPath.length - 1].tokenOut;
        
        for (uint256 i = 0; i < swapPath.length; i++) {                        
            Swap memory swap = swapPath[i];

            uint256 amountBefore = balanceOf(swap.tokenOut);
            
            if (swap.dexType == DexType.UniswapV3 || swap.dexType == DexType.PancakeV3) {
                executeV3Swap(swap, amount);
            } else if (swap.dexType == DexType.MonadexV1) {
                executeMonadexV1Swap(swap, amount);
            } else {
                executeV2Swap(swap, amount);
            }

            uint256 amountAfter = balanceOf(swap.tokenOut);
            require(amountAfter > amountBefore, "swap didn't increase balance");
            amount = amountAfter - amountBefore;
        }

        if (lastToken == WETH_ADDRESS) {
            require(amount >= (amountIn + bidAmount + boostYieldAmount), "amountOut < amountIn");
            IWETH9(WETH_ADDRESS).withdraw(boostYieldAmount);
            shmonad.boostYield{value: boostYieldAmount}();
        } else {
            require(amount >= bidAmount, "amountOut < bidAmount");
        }
        
        return amount;
    }

    function executeV2Swap(Swap memory swap, uint256 amountIn) internal returns (uint256) {
        if (swap.dexType == DexType.UniswapV2) {
            IUniswapV2Pair pair = IUniswapV2Pair(swap.poolAddr);
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            require(pair.token0() == swap.tokenIn || pair.token1() == swap.tokenIn, "Invalid tokenIn");
            require(pair.token0() == swap.tokenOut || pair.token1() == swap.tokenOut, "Invalid tokenOut");

            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, amountIn);
            if (swap.tokenIn == pair.token0()) {
                uint amtOut = getUniswapV2AmountOut(amountIn, reserve0, reserve1);
                pair.swap(0, amtOut, address(this), bytes(""));
                return uint256(amtOut);
            } else {
                uint amtOut = getUniswapV2AmountOut(amountIn, reserve1, reserve0);
                pair.swap(amtOut, 0, address(this), bytes(""));
                return uint256(amtOut);
            }
        } else {
            revert("Invalid DexType");
        }
    }

    function executeMonadexV1Swap(Swap memory swap, uint256 amountIn) internal returns (uint256) {
        IMonadexV1Pair pair = IMonadexV1Pair(swap.poolAddr);
        (uint256 reserve0, uint256 reserve1) = pair.getReserves();
        require(pair.isPoolToken(swap.tokenIn), "Invalid tokenIn");
        require(pair.isPoolToken(swap.tokenOut), "Invalid tokenOut");

        // Get pool tokens to determine if tokenIn is token0 or token1
        (address tokenA, address tokenB) = pair.getPoolTokens();
        bool isTokenAIn = swap.tokenIn == tokenA;
        
        // Get pool fee - needed for accurate swap calculation
        (uint256 feeNumerator, uint256 feeDenominator) = getMonadexPoolFee(pair);
        
        // Calculate the fee factor similarly to UniswapV2 but using the Monadex-specific fee
        uint256 feeFactor = feeDenominator - feeNumerator; // e.g., 997 for 0.3% fee
        
        // Transfer the input token to the pool
        SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, amountIn);
        
        // Calculate expected output amount
        uint256 amountOut;
        if (isTokenAIn) {
            amountOut = getMonadexAmountOut(amountIn, reserve0, reserve1, feeFactor, feeDenominator);
            // Call swap with the correct parameters for tokenA -> tokenB swap
            callMonadexSwap(pair, 0, amountOut, address(this));
        } else {
            amountOut = getMonadexAmountOut(amountIn, reserve1, reserve0, feeFactor, feeDenominator);
            // Call swap with the correct parameters for tokenB -> tokenA swap
            callMonadexSwap(pair, amountOut, 0, address(this));
        }
        
        return amountOut;
    }

    // Helper function to get Monadex pool fee
    function getMonadexPoolFee(IMonadexV1Pair pair) internal view returns (uint256 numerator, uint256 denominator) {
        // Call getPoolFee function on the Monadex pair
        (BubbleV1TypesFraction memory fee) = pair.getPoolFee();
        return (fee.numerator, fee.denominator);
    }

    // Helper function to calculate amount out for Monadex
    function getMonadexAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeFactor,
        uint256 feeDenominator
    ) internal pure returns (uint256) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        
        uint256 amountInWithFee = amountIn * feeFactor;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * feeDenominator) + amountInWithFee;
        return numerator / denominator;
    }

    // Helper function to call Monadex swap function
    function callMonadexSwap(
        IMonadexV1Pair pair,
        uint256 amountAOut,
        uint256 amountBOut,
        address recipient
    ) internal {
        // Create swap params for Monadex
        BubbleV1TypesSwapParams memory swapParams = BubbleV1TypesSwapParams({
            amountAOut: amountAOut,
            amountBOut: amountBOut,
            receiver: recipient,
            hookConfig: BubbleV1TypesHookConfig({
                hookBeforeCall: false,
                hookAfterCall: false
            }),
            data: new bytes(0)
        });
        
        // Call the swap function
        pair.swap(swapParams);
    }
    
    function executeV3Swap(Swap memory swap, uint256 amountIn) internal returns (uint256) {
        uint160 MIN_SQRT_RATIO = 4295128739;
        uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
        IUniswapV3Pool pool = IUniswapV3Pool(swap.poolAddr);
        require(pool.token0() == swap.tokenIn || pool.token1() == swap.tokenIn, "Invalid tokenIn");
        require(pool.token0() == swap.tokenOut || pool.token1() == swap.tokenOut, "Invalid tokenOut");

        if (swap.tokenIn == pool.token0()) {
            (,int256 amountOut) = pool.swap(
                address(this), 
                true, 
                int256(amountIn),
                MIN_SQRT_RATIO + 1,
                bytes("")
            );
            return uint256(-amountOut);
        } else {
            (int256 amountOut,) = pool.swap(
                address(this), 
                false, 
                int256(amountIn), 
                MAX_SQRT_RATIO - 1,
                bytes("")
            );
            return uint256(-amountOut);
        }
    }

    // Secured against attacks for safely storing funds
    function uniswapV3SwapCallback(
      int256 amount0Delta,
      int256 amount1Delta,
      bytes calldata _data
    ) external nonReentrant {
        // Validate the amounts
        require(amount0Delta > 0 || amount1Delta > 0, "Invalid amountDeltas");

        Swap memory swap;
        
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Determine which token we need to pay based on the deltas
        if (amount0Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token0,
                tokenOut: token1
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0
            });
        } else {
            revert("Invalid amountDeltas");
        }

        // Transfer the required tokens to the pool
        if (amount0Delta > 0) {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount0Delta));
        } else {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount1Delta));
        }
    }
    
    // PancakeV3 specific callback for safely handling PancakeV3 swaps
    function pancakeV3SwapCallback(
      int256 amount0Delta,
      int256 amount1Delta,
      bytes calldata _data
    ) external nonReentrant {
        // Validate the amounts
        require(amount0Delta > 0 || amount1Delta > 0, "Invalid amountDeltas");

        Swap memory swap;
        
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Determine which token we need to pay based on the deltas
        if (amount0Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token0,
                tokenOut: token1
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0
            });
        } else {
            revert("Invalid amountDeltas");
        }

        // Transfer the required tokens to the pool
        if (amount0Delta > 0) {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount0Delta));
        } else {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount1Delta));
        }
    }

    // PancakeV3 specific callback for safely handling PancakeV3 swaps
    function zfV3SwapCallback(
      int256 amount0Delta,
      int256 amount1Delta,
      bytes calldata _data
    ) external nonReentrant {
        // Validate the amounts
        require(amount0Delta > 0 || amount1Delta > 0, "Invalid amountDeltas");

        Swap memory swap;
        
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address token0 = pool.token0();
        address token1 = pool.token1();
        
        // Determine which token we need to pay based on the deltas
        if (amount0Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token0,
                tokenOut: token1
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0
            });
        } else {
            revert("Invalid amountDeltas");
        }

        // Transfer the required tokens to the pool
        if (amount0Delta > 0) {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount0Delta));
        } else {
            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, uint256(amount1Delta));
        }
    }

    function getUniswapV2AmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint256 amountOut) {
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Add a function to withdraw any token in case of emergency
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        require(msg.sender == _owner, "INVALID ENTRY");
        SafeTransferLib.safeTransfer(ERC20(token), _owner, amount);
    }
    
    // Make the WETH withdrawal function more secure
    function withdrawWeth(uint256 amount) external nonReentrant {
        require(msg.sender == _owner, "INVALID ENTRY");
        SafeTransferLib.safeTransfer(ERC20(WETH_ADDRESS), _owner, amount);
    }
    
    // Add a function to withdraw ETH if needed
    function withdrawETH(uint256 amount) external nonReentrant {
        require(msg.sender == _owner, "INVALID ENTRY");
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool success, ) = _owner.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function balanceOf(address token) internal view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance;
        } else {
            return ERC20(token).balanceOf(address(this));
        }
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
}
