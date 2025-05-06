// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TxBuilder } from "@atlas/helpers/TxBuilder.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { DAppOperation } from "@atlas/types/DAppOperation.sol";

import { IUniswapV2Router02 } from "../src/interfaces/IUniswapV2Router.sol";
import { IUniswapV2Pair } from "../src/interfaces/IUniswapV2Pair.sol";
import { IUniswapV2Factory } from "../src/interfaces/IUniswapV2Factory.sol";
import { IAtlas } from "../src/interfaces/IAtlas.sol";
import { IAtlasVerification } from "../src/interfaces/IAtlasVerification.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { UniswapV2DAppControl, SwapTokenInfo } from "../src/UniswapV2DAppControl.sol";
import { BoomerSwapSolver, Swap, DexType } from "../src/BoomerSwapSolver.sol";
import { SwapMath } from "../src/SwapMath.sol";


// Uniswap V2 mainnet addresses
address constant SWAP_ROUTER = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Uniswap V2 Router
address payable constant ATLAS_ADDRESS = payable(0x9958Ab9f64EF51194C5378a336D2A0b0A620D31c);
address constant ATLAS_VERIFICATION_ADDRESS = 0x318b5e9806389728b881aea090b7d2330cD7aAd2;
address constant BOOMER_SWAP_SOLVER_ADDRESS = 0xF682591a8779e977bE22aDDDbC39c37c26Da2205;
address constant DAPP_CONTROL_ADDRESS = 0x2EF2eC93aE8902501328B0853052B5Ed2B12f8Cb;

IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(SWAP_ROUTER);
IAtlas constant ATLAS = IAtlas(ATLAS_ADDRESS);
IAtlasVerification constant ATLAS_VERIFICATION = IAtlasVerification(ATLAS_VERIFICATION_ADDRESS);

address constant poolA = 0x7C6E266292850471951F2AAb3C486692F9828289; // uniswap v2
address constant poolB = 0x73f7328343fB94602ca0e2580C441a444facA565; // uniswap v2

address constant weth = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
address constant rare = 0x7607a128d6b8447e587660D9565d824804c0EAD7; 
address constant NATIVE_TOKEN = address(0);

contract UniswapV2DAppControlTest is Test {
    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    address governanceEOA;
    uint256 governancePK;
    TxBuilder txBuilder;

    address executionEnvironment;
    UniswapV2DAppControl control;

    address solverEOA;
    uint256 solverPK;

    address userEOA;
    uint256 userPK;

    address[] _path1 = new address[](2);

    uint256 amountIn = 2 ether;
    uint256 bundlerGasEth = 0;
    uint256 solverBidAmount = 0.5 ether;
    uint256 solverAmountIn = 0.03 ether;
    uint256 boostYieldPct = 0;
    uint64 policyId = 14;    

    Sig sig;

    function setUp() public virtual {
        governancePK = vm.envUint("GOV_PRIVATE_KEY");
        governanceEOA = vm.addr(governancePK);

        control = UniswapV2DAppControl(DAPP_CONTROL_ADDRESS);

        solverPK = vm.envUint("USER_PRIVATE_KEY");
        solverEOA = vm.addr(solverPK);

        userPK = vm.envUint("USER_PRIVATE_KEY");
        userEOA = vm.addr(solverPK);
        
        // Create execution environment
        (executionEnvironment, , ) = ATLAS.getExecutionEnvironment(userEOA, address(control));

        // Setup txBuilder helper
        txBuilder = new TxBuilder({
            _control: address(control),
            _atlas: address(ATLAS),
            _verification: address(ATLAS_VERIFICATION)
        });

        // Set up token paths for swaps
        _path1[0] = weth;
        _path1[1] = rare;
    }

    function test_swapExactTokensForTokens() public {
        // User wants to swap exact WETH for SMON
        bytes memory userOpData = abi.encodeWithSelector(
            0x38ed1739, // swapExactTokensForTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path1,           // path
            executionEnvironment, // to
            block.timestamp * 2 // deadline
        );

        uint256 msgValue = bundlerGasEth;

        Swap[] memory swapPath = new Swap[](2);
        swapPath[0] = Swap(DexType.UniswapV2, poolA, weth, rare);
        swapPath[1] = Swap(DexType.UniswapV2, poolB, rare, weth);

        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, 0, swapPath);

        uint256 userTokenBalanceBefore = _balanceOf(_path1[1], userEOA);
        
        // Do the actual metacall
        
        
        uint256 gasLimit = calculateGasLimit(control, solverOps.length, userOp.gas);
        console.log("gasLimit", gasLimit);

        vm.startPrank(userEOA);
        IERC20(_path1[0]).approve(address(ATLAS), amountIn);

        // Get the calldata for metacall
        bytes memory data = abi.encodeWithSelector(
            IAtlas.metacall.selector,
            userOp,
            solverOps,
            dAppOp,
            address(0)
        );
        // console.logBytes(data);

        (bool success, ) = ATLAS_ADDRESS.call{value: msgValue, gas: gasLimit}(data);
        require(success, "Transaction failed");

        
        // ATLAS.metacall{ value: msgValue, gas: gasLimit }(userOp, solverOps, dAppOp, address(0));
    
        vm.stopPrank();

        uint256 userTokenBalanceAfter = _balanceOf(_path1[1], userEOA);

        console.log("User SMON balance change:", userTokenBalanceAfter - userTokenBalanceBefore);
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
        uint256 msgValue,
        Swap[] memory swapPath
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
            deadline: block.number + 20000,
            data: userOpData
        });

        userOp.sessionKey = governanceEOA;
        userOp.gas = 400_000;

        // build solver operation
        solverOps = new SolverOperation[](1);
        SolverOperation memory solverOp;
        address solverContract;

        (solverContract, solverOp) = _setUpSolver(solverEOA, solverPK, solverBidAmount, userOp, swapPath);        
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
        Swap[] memory swapPath
    )
        internal
        returns (address solverContract, SolverOperation memory solverOp)
    { 
        BoomerSwapSolver solver = BoomerSwapSolver(payable(BOOMER_SWAP_SOLVER_ADDRESS));

        // Create signed solverOp
        solverOp = _buildSolverOp(solverEOA, solverPK, address(solver), bidAmount, userOp, swapPath);
        // vm.stopPrank();

        return (address(solver), solverOp);
    }

    function _buildSolverOp(
        address solverEOA,
        uint256 solverPK,
        address solverContract,
        uint256 bidAmount,
        UserOperation memory userOp,
        Swap[] memory swapPath
    )
        internal
        returns (SolverOperation memory solverOp)
    {
        // Builds the SolverOperation
        solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeCall(BoomerSwapSolver.execute, (swapPath, solverAmountIn, bidAmount, boostYieldPct)),
            solver: solverEOA,
            solverContract: address(solverContract),
            bidAmount: bidAmount,
            value: 0
        });

        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, ATLAS_VERIFICATION.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
    }

    /**
     * @notice Calculates the total gas limit needed for an Atlas transaction
     * @param control The DAppControl contract
     * @param solverOpsLength The number of solver operations
     * @param userOpGas The gas specified in the user operation
     * @return The calculated gas limit for the transaction
     */
    function calculateGasLimit(
        UniswapV2DAppControl control,
        uint256 solverOpsLength,
        uint256 userOpGas
    ) internal view returns (uint256) {
        // Constants
        uint256 _BASE_TX_GAS_USED = 21000;
        uint256 FIXED_GAS_OFFSET = 150000;
        uint256 LOWER_BASE_EXEC_GAS_TOLERANCE = 60_000;
        uint256 TOLERANCE_PER_SOLVER = 33_000;
        
        // Get limits from control
        uint256 dappGasLimit = control.getDAppGasLimit();
        uint256 solverGasLimit = control.getSolverGasLimit();
        uint256 allSolversExecutionGas = solverGasLimit * solverOpsLength;
        
        // Calculate total gas limit
        return userOpGas + 
               dappGasLimit + 
               allSolversExecutionGas + 
               _BASE_TX_GAS_USED + 
               FIXED_GAS_OFFSET - 
               LOWER_BASE_EXEC_GAS_TOLERANCE + 
               TOLERANCE_PER_SOLVER * solverOpsLength;
    }
}