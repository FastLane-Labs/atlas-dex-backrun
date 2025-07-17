// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { IUniswapV2Pair, IUniswapV3Pool, IUniswapV3Factory} from "./interfaces/IUniswap.sol";
import { SafeTransferLib, ERC20 } from "solmate/utils/SafeTransferLib.sol";
import { IAtlas } from "@atlas/interfaces/IAtlas.sol";
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external payable;
    function balanceOf(address account) external view returns (uint256);
}
import { SolverBase } from "@atlas/solver/SolverBase.sol";

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
    MonadexV1
}

struct Swap {
    DexType dexType;
    address poolAddr;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
}

// ----------------------------------------------------------------------------
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// WARNING: DO NOT STORE FUNDS IN THIS CONTRACT
// ----------------------------------------------------------------------------

contract BoomerSwapSolver2 is SolverBase {
    constructor(
        address _weth,
        address _atlas
    ) SolverBase(_weth, _atlas, msg.sender) {}

    function execute(
        Swap[] calldata swapPath
    ) external payable {
        
        for (uint256 i = 0; i < swapPath.length; i++) {                        
            Swap memory swap = swapPath[i];
            
            if (swap.dexType == DexType.UniswapV3) {
                executeV3Swap(swap);
            } else if (swap.dexType == DexType.MonadexV1) {
                executeMonadexV1Swap(swap);
            } else {
                executeV2Swap(swap);
            }
        }
    }

    function executeV2Swap(Swap memory swap) internal returns (uint256) {
        if (swap.dexType == DexType.UniswapV2) {
            IUniswapV2Pair pair = IUniswapV2Pair(swap.poolAddr);
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            require(pair.token0() == swap.tokenIn || pair.token1() == swap.tokenIn, "Invalid tokenIn");
            require(pair.token0() == swap.tokenOut || pair.token1() == swap.tokenOut, "Invalid tokenOut");

            SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, swap.amountIn);
            if (swap.tokenIn == pair.token0()) {
                uint amtOut = getUniswapV2AmountOut(swap.amountIn, reserve0, reserve1);
                pair.swap(0, amtOut, address(this), bytes(""));
                return uint256(amtOut);
            } else {
                uint amtOut = getUniswapV2AmountOut(swap.amountIn, reserve1, reserve0);
                pair.swap(amtOut, 0, address(this), bytes(""));
                return uint256(amtOut);
            }
        } else {
            revert("Invalid DexType");
        }
    }

    function executeMonadexV1Swap(Swap memory swap) internal returns (uint256) {
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
        SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, swap.amountIn);
        
        // Calculate expected output amount
        uint256 amountOut;
        if (isTokenAIn) {
            amountOut = getMonadexAmountOut(swap.amountIn, reserve0, reserve1, feeFactor, feeDenominator);
            // Call swap with the correct parameters for tokenA -> tokenB swap
            callMonadexSwap(pair, 0, amountOut, address(this));
        } else {
            amountOut = getMonadexAmountOut(swap.amountIn, reserve1, reserve0, feeFactor, feeDenominator);
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
    
    function executeV3Swap(Swap memory swap) internal returns (uint256) {
        uint160 MIN_SQRT_RATIO = 4295128739;
        uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
        IUniswapV3Pool pool = IUniswapV3Pool(swap.poolAddr);
        require(pool.token0() == swap.tokenIn || pool.token1() == swap.tokenIn, "Invalid tokenIn");
        require(pool.token0() == swap.tokenOut || pool.token1() == swap.tokenOut, "Invalid tokenOut");

        // Encode the swap data for the callback
        // bytes memory swapData = abi.encode(swap);

        if (swap.tokenIn == pool.token0()) {
            (,int256 amountOut) = pool.swap(
                address(this), 
                true, 
                int256(swap.amountIn),
                MIN_SQRT_RATIO + 1,
                bytes("")
            );
            return uint256(-amountOut);
        } else {
            (int256 amountOut,) = pool.swap(
                address(this), 
                false, 
                int256(swap.amountIn), 
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
    ) external {
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
                tokenOut: token1,
                amountIn: uint256(amount0Delta)
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0,
                amountIn: uint256(amount1Delta)
            });
        } else {
            revert("Invalid amountDeltas");
        }

        SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, swap.amountIn);
    }
    
    // PancakeV3 specific callback for safely handling PancakeV3 swaps
    function pancakeV3SwapCallback(
      int256 amount0Delta,
      int256 amount1Delta,
      bytes calldata _data
    ) external {
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
                tokenOut: token1,
                amountIn: uint256(amount0Delta)
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0,
                amountIn: uint256(amount1Delta)
            });
        } else {
            revert("Invalid amountDeltas");
        }

        SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, swap.amountIn);
    }

    // PancakeV3 specific callback for safely handling PancakeV3 swaps
    function zfV3SwapCallback(
      int256 amount0Delta,
      int256 amount1Delta,
      bytes calldata _data
    ) external {
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
                tokenOut: token1,
                amountIn: uint256(amount0Delta)
            });
        } else if (amount1Delta > 0) {
            swap = Swap({
                dexType: DexType.UniswapV3,
                poolAddr: msg.sender,
                tokenIn: token1,
                tokenOut: token0,
                amountIn: uint256(amount1Delta)
            });
        } else {
            revert("Invalid amountDeltas");
        }

        SafeTransferLib.safeTransfer(ERC20(swap.tokenIn), swap.poolAddr, swap.amountIn);
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
    function withdrawToken(address token, uint256 amount) external {
        require(msg.sender == _owner, "INVALID ENTRY");
        SafeTransferLib.safeTransfer(ERC20(token), _owner, amount);
    }
    
    // Make the WETH withdrawal function more secure
    function withdrawWeth(uint256 amount) external {
        require(msg.sender == _owner, "INVALID ENTRY");
        SafeTransferLib.safeTransfer(ERC20(WETH_ADDRESS), _owner, amount);
    }
    
    // Add a function to withdraw ETH if needed
    function withdrawETH(uint256 amount) external {
        require(msg.sender == _owner, "INVALID ENTRY");
        require(address(this).balance >= amount, "Insufficient ETH balance");
        (bool success, ) = _owner.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    // Allow the contract to receive ETH
    receive() external payable {}
}

// import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
// import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// import { IAtlas } from "../interfaces/IAtlas.sol";
// import { ISolverContract } from "../interfaces/ISolverContract.sol";

// import "../types/SolverOperation.sol";

// interface IWETH9 {
//     function deposit() external payable;
//     function withdraw(uint256 wad) external payable;
// }

// /**
//  * @title SolverBase
//  * @notice A base contract for Solvers
//  * @dev Does safety checks, escrow reconciliation and pays bids.
//  * @dev Works with DAppControls which have set the `invertBidValue` flag to false.
//  * @dev Use `SolverBaseInvertBid` for DAppControls which have set the `invertBidValue` flag to true.
//  */
// contract SolverBase is ISolverContract {
//     address public immutable WETH_ADDRESS;
//     address internal immutable _owner;
//     address internal immutable _atlas;

//     error SolverCallUnsuccessful();
//     error InvalidEntry();
//     error InvalidCaller();

//     constructor(address weth, address atlas, address owner) {
//         WETH_ADDRESS = weth;
//         _owner = owner;
//         _atlas = atlas;
//     }

//     function atlasSolverCall(
//         address solverOpFrom,
//         address executionEnvironment,
//         address bidToken,
//         uint256 bidAmount,
//         bytes calldata solverOpData,
//         bytes calldata forwardedData
//     )
//         external
//         payable
//         virtual
//         safetyFirst(executionEnvironment, solverOpFrom)
//         payBids(executionEnvironment, bidToken, bidAmount)
//     {
//         (bool success,) = address(this).call{ value: msg.value }(solverOpData);
//         if (!success) revert SolverCallUnsuccessful();
//     }

//     modifier safetyFirst(address executionEnvironment, address solverOpFrom) {
//         // Safety checks
//         if (msg.sender != _atlas) revert InvalidEntry();
//         if (solverOpFrom != _owner) revert InvalidCaller();

//         _;

//         (uint256 gasLiability, uint256 borrowLiability) = IAtlas(_atlas).shortfall();
//         uint256 nativeRepayment = borrowLiability < msg.value ? borrowLiability : msg.value;

//         IAtlas(_atlas).reconcile{ value: nativeRepayment }(gasLiability);
//     }

//     modifier payBids(address executionEnvironment, address bidToken, uint256 bidAmount) {
//         _;

//         // After the solverCall logic has executed, pay the solver's bid to the Execution Environment of the current
//         // metacall tx.
        

//         if (bidToken == address(0)) {
//             // Pay bid in ETH
//             uint256 currentBalance = address(this).balance;

//             SafeTransferLib.safeTransferETH(executionEnvironment, currentBalance);
//         } else {
//             uint256 currentBalance = IERC20(bidToken).balanceOf(address(this));
//             // Pay bid in ERC20 (bidToken)
//             SafeTransferLib.safeTransfer(bidToken, executionEnvironment, currentBalance);
//         }
//     }
// }

