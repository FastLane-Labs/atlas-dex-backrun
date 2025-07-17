// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { IUniswapV2Pair, IUniswapV3Pool } from "../src/interfaces/IUniswap.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { BoomerSwapSolver2, Swap, DexType } from "../src/BoomerSwapSolver2.sol";

// Token addresses
address constant WMON = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
address constant CHOG = 0xE0590015A873bF326bd645c3E1266d4db41C4E6B;
address constant NATIVE_TOKEN = address(0);

// Pool addresses
address constant PANCAKE_PAIR = 0x01F4E5aeAe0Dd95048b526a11eB7e20F68802F2e;

contract BoomerSwapSolver2Test is Test {
    BoomerSwapSolver2 solver;
    
    // Test amounts
    uint256 constant SMALL_AMOUNT = 0.1 ether;
    
    function setUp() public {
        // Deploy the solver with a mock Atlas address
        address mockAtlas = address(0x1234567890123456789012345678901234567890);
        solver = new BoomerSwapSolver2(WMON, mockAtlas);
        
        // Fund the solver with tokens for testing
        deal(WMON, address(solver), 20 ether); // Increased to ensure enough for multi-hop
        // deal(CHOG, address(solver), 100 ether);
        
        // Fund the test contract with ETH
        vm.deal(address(this), 100 ether);
    }
    
    // Helper function to get token balance
    function getBalance(address token, address account) internal view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return account.balance; // WMON is WETH equivalent
        } else {
            return IERC20(token).balanceOf(account);
        }
    }
    
    function test_PancakeV3Swap() public {
        // Create a PancakeV3 swap path
        Swap[] memory swapPath = new Swap[](1);
        swapPath[0] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: PANCAKE_PAIR,
            tokenIn: WMON,
            tokenOut: CHOG,
            amountIn: SMALL_AMOUNT
        });
        
        uint256 balanceBefore = getBalance(CHOG, address(solver));
        
        // Execute the swap
        solver.execute(swapPath);
        
        uint256 balanceAfter = getBalance(CHOG, address(solver));
        
        console.log("Balance change:", balanceAfter - balanceBefore);
        
        assertGt(balanceAfter, balanceBefore, "Balance should have increased");
    }
    
    function test_PancakeMultiHopSwap() public {
        // Create a multi-hop swap using two different pools
        // Based on the transaction: WMON -> CHOG through two different pools
        Swap[] memory swapPath = new Swap[](2);
        swapPath[0] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: 0x96c8dfe099cEb7fe7cB9e5e070858f66363BD75C, // First pool
            tokenIn: WMON,
            tokenOut: CHOG,
            amountIn: 0.8 ether
        });
        swapPath[1] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: 0x3505001F8141cb99fC28E58Cf1843309cFFaC868, // Second pool
            tokenIn: WMON,
            tokenOut: CHOG,
            amountIn: 0.2 ether
        });
        
        uint256 balanceBefore = getBalance(CHOG, address(solver));
        
        // Execute the multi-hop swap with 1 ETH
        solver.execute(swapPath);
        
        uint256 balanceAfter = getBalance(CHOG, address(solver));
        
        console.log("Multi-hop balance change:", balanceAfter - balanceBefore);
        
        assertGt(balanceAfter, balanceBefore, "Balance should have increased");
    }
    
    function test_RealMultiHopSwap() public {
        // Test based on real transaction data: 3-hop CHOG -> WMON
        Swap[] memory swapPath = new Swap[](3);
        swapPath[0] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: 0x01F4E5aeAe0Dd95048b526a11eB7e20F68802F2e,
            tokenIn: CHOG,
            tokenOut: WMON,
            amountIn: 75925957469327828927
        });
        swapPath[1] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: 0x3505001F8141cb99fC28E58Cf1843309cFFaC868,
            tokenIn: CHOG,
            tokenOut: WMON,
            amountIn: 35355572707594437538
        });
        swapPath[2] = Swap({
            dexType: DexType.UniswapV3,
            poolAddr: 0x96c8dfe099cEb7fe7cB9e5e070858f66363BD75C,
            tokenIn: CHOG,
            tokenOut: WMON,
            amountIn: 29718469823077733535
        });
        
        // Fund the solver with CHOG tokens for this test
        deal(CHOG, address(solver), 150 ether);
        
        // Check WMON ERC20 balance, not ETH balance
        uint256 balanceBefore = IERC20(WMON).balanceOf(address(solver));
        
        // Execute the 3-hop swap
        solver.execute(swapPath);
        
        uint256 balanceAfter = IERC20(WMON).balanceOf(address(solver));
        
        console.log("Real 3-hop balance change:", balanceAfter - balanceBefore);
        
        assertGt(balanceAfter, balanceBefore, "Balance should have increased");
    }
} 