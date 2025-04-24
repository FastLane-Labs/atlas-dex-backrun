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
import { UniswapV3DAppControl, SwapTokenInfo } from "../src/UniswapV3DAppControl.sol";
import "../src/interfaces/ISwapRouter.sol";
import "../src/interfaces/IUniswapV3Factory.sol";
import "../src/interfaces/IWETH.sol";

address constant SWAP_ROUTER = 0x1B8eea9315bE495187D873DA7773a874545D9D48;
address constant FACTORY_ADDRESS = 0x38015D05f4fEC8AFe15D7cc0386a126574e8077B;

address constant WETH_ADDRESS_BASE = 0x4200000000000000000000000000000000000006;
address constant CBBTC_ADDRESS_BASE = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
address constant USDC_ADDRESS_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant ETH = address(0);
address constant NATIVE_TOKEN = address(0);

ISwapRouter constant ROUTER = ISwapRouter(SWAP_ROUTER);
IUniswapV3Factory constant FACTORY = IUniswapV3Factory(FACTORY_ADDRESS);

IWETH constant WETH_BASE = IWETH(WETH_ADDRESS_BASE);
IERC20 constant CBBTC_BASE = IERC20(CBBTC_ADDRESS_BASE);
IERC20 constant USDC_BASE = IERC20(USDC_ADDRESS_BASE);

contract UniswapV3DAppControlTest is BaseTest {
    TxBuilder public txBuilder;
    address executionEnvironment;
    UniswapV3DAppControl control;
    address BID_TOKEN; // will be set to value in DAppControl in setUp
    uint256 GOV_PAYOUT_PERCENTAGE; // will be set to value in DAppControl in setUp
    address REWARD_ADDRESS; // will be set to value in DAppControl in setUp

    uint24[] _fees = new uint24[](2);
    address[] _tokens = new address[](3);

    address weth_usdc_pool = FACTORY.getPool(WETH_ADDRESS_BASE, USDC_ADDRESS_BASE, _fees[0]);
    address usdc_cbbtc_pool = FACTORY.getPool(USDC_ADDRESS_BASE, CBBTC_ADDRESS_BASE, _fees[1]);

    uint24 FEE = 80;
    address weth_cbbtc_pool = FACTORY.getPool(WETH_ADDRESS_BASE, CBBTC_ADDRESS_BASE, FEE);

    uint256 amountIn = 1 ether;
    uint256 amountOut = 3_200_000;
    uint256 amountInMax = 1 ether;
    address tokenIn = WETH_ADDRESS_BASE;
    address tokenOut = CBBTC_ADDRESS_BASE;
    uint256 bundlerGasEth = 1e16;

    Sig sig;

    function setUp() public virtual override {
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        vm.startPrank(governanceEOA);
        control = new UniswapV3DAppControl(address(atlas), SWAP_ROUTER, ETH, governanceEOA, 5000, 0.005 ether); //50%
            // gov payout
        atlasVerification.initializeGovernance(address(control));
        vm.stopPrank();

        vm.startPrank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(control));
        vm.stopPrank();

        //txBuilder helper
        txBuilder = new TxBuilder({
            _control: address(control),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        BID_TOKEN = control.bidToken();
        REWARD_ADDRESS = control.govPayoutAddr();
        GOV_PAYOUT_PERCENTAGE = control.govPercent();

        _fees[0] = 80;
        _fees[1] = 350;

        _tokens[0] = WETH_ADDRESS_BASE;
        _tokens[1] = USDC_ADDRESS_BASE;
        _tokens[2] = CBBTC_ADDRESS_BASE;

        deal(userEOA, 10 ether);
        deal(tokenIn, userEOA, amountIn);
        deal(tokenOut, userEOA, amountOut * 2);
    }

    function test_exactInputSingle_native() public {
        // get data for userOp
        ISwapRouter.ExactInputSingleParams memory params =
            abi.decode(getParams(0), (ISwapRouter.ExactInputSingleParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactInputSingle.selector, params);

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactOutputSingle_native() public {
        // get data for userOp
        ISwapRouter.ExactOutputSingleParams memory params =
            abi.decode(getParams(1), (ISwapRouter.ExactOutputSingleParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactOutputSingle.selector, params);

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactInput_native() public {
        // get data for userOp
        ISwapRouter.ExactInputParams memory params = abi.decode(getParams(2), (ISwapRouter.ExactInputParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactInput.selector, params);

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountIn);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactOutput_native() public {
        // get data for userOp
        ISwapRouter.ExactOutputParams memory params = abi.decode(getParams(3), (ISwapRouter.ExactOutputParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactOutput.selector, params);

        uint256 msgValue = amountIn + bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, amountIn);

        uint256 userTokenBalanceBefore = _balanceOf(tokenOut, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenIn).approve(address(atlas), amountIn);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(tokenOut, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactInputSingle() public {
        // get data for userOp
        ISwapRouter.ExactInputSingleParams memory params =
            abi.decode(getParams(0), (ISwapRouter.ExactInputSingleParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactInputSingle.selector, params);

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

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactOutputSingle() public {
        // get data for userOp
        ISwapRouter.ExactOutputSingleParams memory params =
            abi.decode(getParams(1), (ISwapRouter.ExactOutputSingleParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactOutputSingle.selector, params);

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

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactInput() public {
        // get data for userOp
        ISwapRouter.ExactInputParams memory params = abi.decode(getParams(2), (ISwapRouter.ExactInputParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactInput.selector, params);

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

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_exactOutput() public {
        // get data for userOp
        ISwapRouter.ExactOutputParams memory params = abi.decode(getParams(3), (ISwapRouter.ExactOutputParams));
        bytes memory userOpData = abi.encodeWithSelector(ROUTER.exactOutput.selector, params);

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

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_multicall_exactInput() public {
        // get data for userOp
        ISwapRouter.ExactInputParams memory params = abi.decode(getParams(4), (ISwapRouter.ExactInputParams));

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ROUTER.exactInput.selector, params);
        data[1] = abi.encodeWithSelector(ROUTER.unwrapWETH9.selector, 0, executionEnvironment);

        bytes memory userOpData = abi.encodeWithSelector(ROUTER.multicall.selector, data);

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(ETH, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenOut).approve(address(atlas), amountOut);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(ETH, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);
    }

    function test_multicall_exactOutput() public {
        // get data for userOp
        ISwapRouter.ExactOutputParams memory params = abi.decode(getParams(5), (ISwapRouter.ExactOutputParams));

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ROUTER.exactOutput.selector, params);
        data[1] = abi.encodeWithSelector(ROUTER.unwrapWETH9.selector, 0, executionEnvironment);

        bytes memory userOpData = abi.encodeWithSelector(ROUTER.multicall.selector, data);

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0);

        uint256 userTokenBalanceBefore = _balanceOf(ETH, userEOA);

        // Do the actual metacall
        vm.startPrank(userEOA);
        IERC20(tokenOut).approve(address(atlas), amountOut * 2);
        atlas.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(ETH, userEOA);

        console.log(userTokenBalanceAfter - userTokenBalanceBefore);
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

    function encodePath(
        address[] memory path,
        uint24[] memory fees,
        bool exactOutput
    )
        public
        pure
        returns (bytes memory)
    {
        bytes memory res;

        if (!exactOutput) {
            // Original forward encoding:
            for (uint256 i = 0; i < fees.length; i++) {
                res = abi.encodePacked(res, path[i], fees[i]);
            }
            res = abi.encodePacked(res, path[path.length - 1]);
        } else {
            // Reverse encoding:
            // Start with the last token
            res = abi.encodePacked(path[path.length - 1]);
            // Go backwards through fees and prepend path tokens in reverse
            for (uint256 i = fees.length; i > 0; i--) {
                res = abi.encodePacked(res, fees[i - 1], path[i - 1]);
            }
        }

        return res;
    }

    function getParams(uint8 swapType) internal view returns (bytes memory params) {
        if (swapType == 0) {
            // ExactInputSingleParams
            ISwapRouter.ExactInputSingleParams memory exactInputSingleParams = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE,
                recipient: executionEnvironment,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            params = abi.encode(exactInputSingleParams);
        } else if (swapType == 1) {
            // ExactOutputSingleParams
            ISwapRouter.ExactOutputSingleParams memory exactOutputSingleParams = ISwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE,
                recipient: executionEnvironment,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            });
            params = abi.encode(exactOutputSingleParams);
        } else if (swapType == 2) {
            // ExactInputParams (multi-hop)
            ISwapRouter.ExactInputParams memory exactInputParams = ISwapRouter.ExactInputParams({
                path: encodePath(_tokens, _fees, false),
                recipient: executionEnvironment,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0
            });
            params = abi.encode(exactInputParams);
        } else if (swapType == 3) {
            // ExactOutputParams (multi-hop)
            ISwapRouter.ExactOutputParams memory exactOutputParams = ISwapRouter.ExactOutputParams({
                path: encodePath(_tokens, _fees, true),
                recipient: executionEnvironment,
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMax
            });
            params = abi.encode(exactOutputParams);
        } else if (swapType == 4) {
            // ExactInputParams (multi-hop)
            ISwapRouter.ExactInputParams memory exactInputParams = ISwapRouter.ExactInputParams({
                path: encodePath(_tokens, _fees, true),
                recipient: address(ROUTER),
                deadline: block.timestamp,
                amountIn: amountOut,
                amountOutMinimum: 0
            });
            params = abi.encode(exactInputParams);
        } else if (swapType == 5) {
            // ExactOutputParams (multi-hop)
            ISwapRouter.ExactOutputParams memory exactOutputParams = ISwapRouter.ExactOutputParams({
                path: encodePath(_tokens, _fees, false),
                recipient: address(ROUTER),
                deadline: block.timestamp,
                amountOut: amountIn,
                amountInMaximum: amountOut * 2
            });
            params = abi.encode(exactOutputParams);
        } else {
            revert("Invalid swap type");
        }

        return params;
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
