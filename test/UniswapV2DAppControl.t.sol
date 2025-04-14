// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { BaseTest } from "@atlas-test/base/BaseTest.t.sol";

import { SolverBase } from "@atlas/solver/SolverBase.sol";
import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";

import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";
import { UniswapV2DAppControl, SwapTokenInfo } from "../src/UniswapV2DAppControl.sol";
import { IUniswapV2Router02 } from "../src/interfaces/IUniswapV2Router.sol";
import { IUniswapV2Pair } from "../src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "../src/interfaces/IUniswapV2Factory.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SwapMath } from "../src/SwapMath.sol";

// Uniswap V2 mainnet addresses
address constant SWAP_ROUTER = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Uniswap V2 Router
address constant FACTORY = 0x0085388Da29e74b66ac6b6fF690973bE05403f67;
address constant ATLAS = 0x81E8c782Abbe606366C246C6c85475009ff6fb84;

IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(SWAP_ROUTER);

// Token addresses
address constant WETH_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701; // Mainnet WETH
address constant DAI_ADDRESS = 0xe1d2439b75fb9746E7Bc6cB777Ae10AA7f7ef9c5; // Mainnet DAI
address constant USDC_ADDRESS = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea; // Mainnet USDC
address constant ETH = address(0);
address constant NATIVE_TOKEN = address(0);

IERC20 constant WETH = IERC20(WETH_ADDRESS);
IERC20 constant DAI = IERC20(DAI_ADDRESS);
IERC20 constant USDC = IERC20(USDC_ADDRESS);

contract UniswapV2DAppControlTest is BaseTest {
    TxBuilder public txBuilder;
    address executionEnvironment;
    UniswapV2DAppControl control;
    address BID_TOKEN; // will be set to value in DAppControl in setUp
    uint256 GOV_PAYOUT_PERCENTAGE; // will be set to value in DAppControl in setUp
    address REWARD_ADDRESS; // will be set to value in DAppControl in setUp

    address[] _path1 = new address[](2);
    address[] _path2 = new address[](3);

    uint256 amountIn = 1 ether;
    uint256 amountOut = 1 * 1e15; // 1000 DAI
    uint256 amountInMax = 2 ether;
    address tokenIn = WETH_ADDRESS;
    address tokenOut = DAI_ADDRESS;
    uint256 bundlerGasEth = 1e16;

    Sig sig;

    function setUp() public virtual override {
        // super.setUp(); // Use the BaseTest setUp
        __createAndLabelAccounts();
        __deployAtlasContracts();
        
        // Create governance
        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        // Deploy the control contract
        vm.startPrank(governanceEOA);
        control = new UniswapV2DAppControl(address(atlas), ETH, governanceEOA, 5000, 0.005 ether); //50% gov payout
        atlasVerification.initializeGovernance(address(control));
        vm.stopPrank();

        // Create execution environment
        vm.startPrank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(control));
        vm.stopPrank();

        // Setup txBuilder helper
        txBuilder = new TxBuilder({
            _control: address(control),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        // Get contract parameters
        BID_TOKEN = control.bidToken();
        REWARD_ADDRESS = control.govPayoutAddr();
        GOV_PAYOUT_PERCENTAGE = control.govPercent();

        // Set up token paths for swaps
        _path1[0] = WETH_ADDRESS;
        _path1[1] = DAI_ADDRESS;

        _path2[0] = WETH_ADDRESS;
        _path2[1] = USDC_ADDRESS;
        _path2[2] = DAI_ADDRESS;

        // Fund user with ETH and tokens
        deal(userEOA, 10 ether);
        deal(tokenIn, userEOA, 10 ether);
        deal(tokenOut, userEOA, 10 ether);

            // Add funding for governance
        deal(governanceEOA, 2e18);
        vm.startPrank(governanceEOA);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);
        vm.stopPrank();
    }

    function test_swapExactTokensForTokens() public {
        // User wants to swap exact WETH for DAI
        bytes memory userOpData = abi.encodeWithSelector(
            0x38ed1739, // swapExactTokensForTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);
        
        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountIn);
        
        // Use try/catch to get error details
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapTokensForExactTokens() public {
        // User wants exact DAI for WETH
        bytes memory userOpData = abi.encodeWithSelector(
            0x8803dbee, // swapTokensForExactTokens selector
            amountOut,        // amountOut
            amountInMax,      // amountInMax
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountInMax);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapExactETHForTokens() public {
        // User wants to swap exact ETH for DAI
        bytes memory userOpData = abi.encodeWithSelector(
            0x7ff36ab5, // swapExactETHForTokens selector
            1,                // amountOutMin (low for testing)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapTokensForExactETH() public {
        uint256 reserves0;
        uint256 reserves1;
        (reserves0, reserves1, ) = IUniswapV2Pair(IUniswapV2Factory(FACTORY).getPair(WETH_ADDRESS, DAI_ADDRESS)).getReserves();
        uint256 amountIn = SwapMath.getAmountIn(amountOut, reserves1, reserves0);
        // User wants exact ETH for DAI
        address[] memory reversePath = new address[](2);
        reversePath[0] = DAI_ADDRESS;
        reversePath[1] = WETH_ADDRESS;

        bytes memory userOpData = abi.encodeWithSelector(
            0x4a25d94a, // swapTokensForExactETH selector
            amountOut,        // amountOut (ETH)
            amountIn,        // amountInMax (DAI)
            reversePath,      // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userEthBalanceBefore = _balanceOf(ETH, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(DAI_ADDRESS).approve(address(atlas), amountIn);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userEthBalanceAfter = _balanceOf(ETH, userEOA);

        console.log("User ETH balance change:", userEthBalanceAfter - userEthBalanceBefore);
        assertGt(userEthBalanceAfter - userEthBalanceBefore, 0);
    }

    function test_swapExactTokensForETH() public {
        // User wants to swap exact DAI for ETH
        address[] memory reversePath = new address[](2);
        reversePath[0] = DAI_ADDRESS;
        reversePath[1] = WETH_ADDRESS;

        bytes memory userOpData = abi.encodeWithSelector(
            0x18cbafe5, // swapExactTokensForETH selector
            amountOut,        // amountIn (DAI)
            1,                // amountOutMin (ETH, low for testing)
            reversePath,      // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userEthBalanceBefore = _balanceOf(ETH, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(DAI_ADDRESS).approve(address(atlas), amountOut);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userEthBalanceAfter = _balanceOf(ETH, userEOA);

        console.log("User ETH balance change:", userEthBalanceAfter - userEthBalanceBefore);
        assertGt(userEthBalanceAfter - userEthBalanceBefore, 0);
    }

    function test_swapETHForExactTokens() public {
        uint256 reserves0;
        uint256 reserves1;
        (reserves0, reserves1, ) = IUniswapV2Pair(IUniswapV2Factory(FACTORY).getPair(WETH_ADDRESS, DAI_ADDRESS)).getReserves();
        uint256 amountIn = SwapMath.getAmountIn(amountOut, reserves0, reserves1);
        // User wants exact DAI for ETH
        bytes memory userOpData = abi.encodeWithSelector(
            0xfb3bdb41, // swapETHForExactTokens selector
            amountOut,        // amountOut (DAI)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapExactTokensForTokensSupportingFeeOnTransferTokens() public {
        // User wants to swap exact WETH for DAI with fee-on-transfer support
        bytes memory userOpData = abi.encodeWithSelector(
            0x5c11d795, // swapExactTokensForTokensSupportingFeeOnTransferTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountIn);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapExactETHForTokensSupportingFeeOnTransferTokens() public {
        // User wants to swap exact ETH for DAI with fee-on-transfer support
        bytes memory userOpData = abi.encodeWithSelector(
            0xb6f9de95, // swapExactETHForTokensSupportingFeeOnTransferTokens selector
            1,                // amountOutMin (low for testing)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_swapExactTokensForETHSupportingFeeOnTransferTokens() public {
        // User wants to swap exact DAI for ETH with fee-on-transfer support
        address[] memory reversePath = new address[](2);
        reversePath[0] = DAI_ADDRESS;
        reversePath[1] = WETH_ADDRESS;

        bytes memory userOpData = abi.encodeWithSelector(
            0x791ac947, // swapExactTokensForETHSupportingFeeOnTransferTokens selector
            amountOut,        // amountIn (DAI)
            1,                // amountOutMin (ETH, low for testing)
            reversePath,      // path
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userEthBalanceBefore = _balanceOf(ETH, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(DAI_ADDRESS).approve(address(atlas), amountOut);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userEthBalanceAfter = _balanceOf(ETH, userEOA);

        console.log("User ETH balance change:", userEthBalanceAfter - userEthBalanceBefore);
        assertGt(userEthBalanceAfter - userEthBalanceBefore, 0);
    }

    function test_multiHopSwap() public {
        // User wants to swap WETH for DAI through USDC
        bytes memory userOpData = abi.encodeWithSelector(
            0x38ed1739, // swapExactTokensForTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path2,           // multi-hop path: WETH -> USDC -> DAI
            executionEnvironment, // to
            block.timestamp + 1800 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(DAI_ADDRESS, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountIn);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(DAI_ADDRESS, userEOA);

        console.log("User DAI balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    // balanceOf helper that supports ERC20 and native token
    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function buildOperations(
        bytes memory userOpData,
        uint256 msgValue
    )
        internal
        returns (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp)
    {
        // build user operation
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(ROUTER),
            maxFeePerGas: tx.gasprice + 1,
            value: msgValue,
            deadline: block.number + 2,
            data: userOpData
        });

        userOp.sessionKey = governanceEOA;

        // build solver operation
        solverOps = new SolverOperation[](1);

        SolverOperation memory solverOp;
        address solverContract;

        (solverContract, solverOp) = _setUpSolver(solverOneEOA, solverOnePK, 0.03 ether, userOp, true);

        solverOps[0] = solverOp;

        // build dApp operation
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        dAppOp.bundler = userEOA;

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return (userOp, solverOps, dAppOp);
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        UserOperation memory userOp,
        bool shouldSucceed
    )
        internal
        returns (address solverContract, SolverOperation memory solverOp)
    {
        vm.startPrank(solverEOA);
        // Make sure solver has 1 AtlETH bonded in Atlas
        uint256 bonded = atlas.balanceOfBonded(solverEOA);
        if (bonded < 1e18) {
            uint256 atlETHBalance = atlas.balanceOf(solverEOA);
            if (atlETHBalance < 1e18) {
                deal(solverEOA, 1e18 - atlETHBalance);
                atlas.deposit{ value: 1e18 - atlETHBalance }();
            }
            atlas.bond(1e18 - bonded);
        }

        // Deploy solver contract
        MockETHSolver solver = new MockETHSolver(ETH, address(atlas));
        solver.setShouldSucceed(shouldSucceed);

        // Give bidAmount of ETH to solver contract
        if (BID_TOKEN == ETH) {
            // ETH as bidToken
            deal(address(solver), bidAmount);
        } else {
            // ERC20 as bidToken
            deal(BID_TOKEN, address(solver), bidAmount);
        }

        // Create signed solverOp
        solverOp = _buildSolverOp(solverEOA, solverPK, address(solver), bidAmount, userOp);
        vm.stopPrank();

        return (address(solver), solverOp);
    }

    function _buildSolverOp(
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount,
        UserOperation memory userOp
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        // Builds the SolverOperation
        solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeCall(MockETHSolver.solve, ()),
            solver: solverEOA,
            solverContract: address(solverContract),
            bidAmount: bidAmount,
            value: 0
        });

        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }
}

// Just bids `bidAmount` in ETH token - doesn't do anything else
contract MockETHSolver is SolverBase {
    bool internal s_shouldSucceed;

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {
        s_shouldSucceed = true; // should succeed by default, can be set to false
    }

    function shouldSucceed() public view returns (bool) {
        return s_shouldSucceed;
    }

    function setShouldSucceed(bool succeed) public {
        s_shouldSucceed = succeed;
    }

    function solve() public view onlySelf {
        require(s_shouldSucceed, "Solver failed intentionally");

        // The solver bid representing user's minAmountUserBuys of tokenUserBuys is sent to the
        // Execution Environment in the payBids modifier logic which runs after this function ends.
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}
