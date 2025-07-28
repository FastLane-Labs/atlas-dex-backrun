// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";
import { SolverBase } from "@atlas/solver/SolverBase.sol";

import { IUniswapV2Router02 } from "../src/interfaces/IUniswapV2Router.sol";
import { IAtlas } from "../src/interfaces/IAtlas.sol";
import { IAtlasVerification } from "../src/interfaces/IAtlasVerification.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { BackrunDAppControl, SwapTokenInfo } from "../src/BackrunDAppControl.sol";
import { IShMonad } from "../src/interfaces/IShMonad.sol";

// Uniswap V2 mainnet addresses
address constant SWAP_ROUTER = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Uniswap V2 Router
address payable constant ATLAS_ADDRESS = payable(0xbB010Cb7e71D44d7323aE1C267B333A48D05907C);
address constant ATLAS_VERIFICATION_ADDRESS = 0x1D388b1B87E3fbd08cF30e54b4Bcaf21052d90a9;
address constant SHMONAD_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;

IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(SWAP_ROUTER);
IAtlas constant ATLAS = IAtlas(ATLAS_ADDRESS);
IAtlasVerification constant ATLAS_VERIFICATION = IAtlasVerification(ATLAS_VERIFICATION_ADDRESS);

address constant weth = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
address constant rare = 0x7607a128d6b8447e587660D9565d824804c0EAD7; 
address constant NATIVE_TOKEN = address(0);

contract BackrunDAppControlTest is Test {
    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    address governanceEOA;
    uint256 governancePK;
    TxBuilder txBuilder;

    BackrunDAppControl control;

    address solverEOA;
    uint256 solverPK;

    address userEOA;
    uint256 userPK;

    address[] _path1 = new address[](2);
    address[] _path2 = new address[](2);
    uint256 amountIn = 0.1 ether;
    uint256 bundlerGasEth = 0.000001 ether;
    uint256 solverBidAmountETH = 0.001 ether;
    uint256 solverBidAmount = 15000 ether;
    uint256 solverAmountIn = 0.03 ether;
    uint256 solverGas = 500_000;
    uint256 userGas = 400_000;
    Sig sig;

    function setUp() public virtual {
        governancePK = vm.envUint("GOV_PRIVATE_KEY");
        governanceEOA = vm.addr(governancePK);

        vm.deal(governanceEOA, 100 ether);
        vm.startPrank(governanceEOA);

        control = new BackrunDAppControl(ATLAS_ADDRESS, governanceEOA, 1000); //50% gov payout
        ATLAS_VERIFICATION.initializeGovernance(payable(address(control)));
        control.addRouter(address(ROUTER));
        
        vm.stopPrank();

        solverPK = vm.envUint("USER_PRIVATE_KEY");
        solverEOA = vm.addr(solverPK);

        userPK = vm.envUint("USER_PRIVATE_KEY");
        userEOA = vm.addr(solverPK);

        // Setup txBuilder helper
        txBuilder = new TxBuilder({
            _control: payable(address(control)),
            _atlas: address(ATLAS),
            _verification: address(ATLAS_VERIFICATION)
        });

        // Set up token paths for swaps
        _path1[0] = weth;
        _path1[1] = rare;

    }

    function test_swapExactTokensForTokens() public {
        // User wants to swap exact WETH for SMON
        bytes memory swapData = abi.encodeWithSelector(
            0x38ed1739, // swapExactTokensForTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path1,           // path
            userEOA, // to
            block.timestamp * 2 // deadline
        );

        bool bidTokenIsOutputToken = true;
        address bidToken = bidTokenIsOutputToken ? rare : NATIVE_TOKEN;

        SwapTokenInfo memory swapInfo = SwapTokenInfo({
            inputToken: weth,
            inputAmount: amountIn,
            outputToken: rare,
            outputMin: 1,
            bidTokenIsOutputToken: bidTokenIsOutputToken,
            target: address(ROUTER),
            swapData: swapData
        });

        address refundRecipient = makeAddr("REFUND_RECIPIENT");

        bytes memory userOpData = abi.encodeWithSelector(
            BackrunDAppControl.swap.selector,
            swapInfo,
            refundRecipient,
            1000
        );

        uint256 msgValue = bundlerGasEth;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, msgValue, bidToken);

        uint256 userTokenBalanceBefore = _balanceOf(_path1[1], userEOA);

        vm.startPrank(userEOA);
        IERC20(_path1[0]).approve(address(ATLAS), amountIn);
        
        uint256 userBalanceBefore = _balanceOf(NATIVE_TOKEN, userEOA);
        uint256 gasBefore = gasleft();
        ATLAS.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        uint256 gasAfter = gasleft();
        console.log("gas used", gasBefore - gasAfter);
    
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(_path1[1], userEOA);

        console.log("User SMON balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);

        uint256 refundAmount = _balanceOf(bidToken, refundRecipient);
        console.log("refund amount", refundAmount);
        assertGt(refundAmount, 0);
    }

    function test_swapExactETHForTokens() public {
        // User wants to swap exact ETH for SMON
        bytes memory swapData = abi.encodeWithSelector(
            0x7ff36ab5, // swapExactETHForTokens selector
            1,                // amountOutMin (low for testing)
            _path1,           // path
            userEOA, // to
            block.timestamp * 2 // deadline
        );

        bool bidTokenIsOutputToken = true;
        address bidToken = bidTokenIsOutputToken ? rare : NATIVE_TOKEN;

        SwapTokenInfo memory swapInfo = SwapTokenInfo({
            inputToken: NATIVE_TOKEN,
            inputAmount: amountIn,
            outputToken: rare,
            outputMin: 1,
            bidTokenIsOutputToken: bidTokenIsOutputToken,
            target: address(ROUTER),
            swapData: swapData
        });

        address refundRecipient = makeAddr("REFUND_RECIPIENT");

        bytes memory userOpData = abi.encodeWithSelector(
            BackrunDAppControl.swap.selector,
            swapInfo,
            refundRecipient,
            1000
        );

        uint256 msgValue = amountIn;

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, msgValue, bidToken);

        uint256 userTokenBalanceBefore = _balanceOf(_path1[1], userEOA);

        vm.startPrank(userEOA);
        
        uint256 gasBefore = gasleft();
        ATLAS.metacall{ value: msgValue }(userOp, solverOps, dAppOp, address(0));
        uint256 gasAfter = gasleft();
        console.log("gas used", gasBefore - gasAfter);
    
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(_path1[1], userEOA);

        console.log("User SMON balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
        assertGt(userTokenBalanceAfter - userTokenBalanceBefore, 0);

        uint256 refundAmount = _balanceOf(bidToken, refundRecipient);
        console.log("refund amount", refundAmount);
        assertGt(refundAmount, 0);
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
        uint256 msgValue,
        address bidToken
    )
        internal
        returns (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp)
    {
        // build user operation
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: payable(address(control)),
            maxFeePerGas: tx.gasprice + 1,
            value: msgValue,
            deadline: block.number + 20000,
            data: userOpData
        });

        userOp.sessionKey = governanceEOA;
        userOp.gas = userGas;

        // build solver operation
        solverOps = new SolverOperation[](1);
        SolverOperation memory solverOp;
        address solverContract;

        (solverContract, solverOp) = _setUpSolver(solverEOA, solverPK, solverBidAmount, userOp, bidToken);        
        solverOps[0] = solverOp;

        // build dApp operation
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        dAppOp.bundler = userEOA;

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, ATLAS_VERIFICATION.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return (userOp, solverOps, dAppOp);
    }

    function _setUpSolver(
        address solverEOA,
        uint256 solverPK,
        uint256 bidAmount,
        UserOperation memory userOp,
        address bidToken
    )
        internal
        returns (address solverContract, SolverOperation memory solverOp)
    { 
        vm.startPrank(userEOA);
        SimpleSolver solver = new SimpleSolver(weth, ATLAS_ADDRESS);
        deal(weth, address(solver), 100 ether);
        deal(bidToken, address(solver), bidAmount);

        // Create signed solverOp
        solverOp = _buildSolverOp(solverEOA, solverPK, address(solver), bidAmount, userOp, bidToken);
        vm.stopPrank();

        return (address(solver), solverOp);
    }

    function _buildSolverOp(
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount,
        UserOperation memory userOp,
        address bidToken
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        // Builds the SolverOperation
        solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeCall(SimpleSolver.solve, ()),
            solver: solverEOA,
            solverContract: address(solverContract),
            bidAmount: bidAmount,
            value: 0
        });
        solverOp.bidToken = bidToken;
        solverOp.gas = solverGas;

        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, ATLAS_VERIFICATION.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }
}

// Just bids `bidAmount` in ETH token - doesn't do anything else
contract SimpleSolver is SolverBase {
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