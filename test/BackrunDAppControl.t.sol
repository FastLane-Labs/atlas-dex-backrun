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

address constant SWAP_ROUTER = 0xCa810D095e90Daae6e867c19DF6D9A8C56db2c89; // Bean DEX
address payable constant ATLAS_ADDRESS = payable(0xbB010Cb7e71D44d7323aE1C267B333A48D05907C);
address constant ATLAS_VERIFICATION_ADDRESS = 0x1D388b1B87E3fbd08cF30e54b4Bcaf21052d90a9;
address constant SHMONAD_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;

IUniswapV2Router02 constant ROUTER = IUniswapV2Router02(SWAP_ROUTER);
IAtlas constant ATLAS = IAtlas(ATLAS_ADDRESS);
IAtlasVerification constant ATLAS_VERIFICATION = IAtlasVerification(ATLAS_VERIFICATION_ADDRESS);

address constant weth = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
address constant rare = 0x7607a128d6b8447e587660D9565d824804c0EAD7; 
address constant NATIVE_TOKEN = address(0);

/**
 * @title EIP-7702 Smart Wallet Implementation
 * @notice This contract implements EIP-7702 functionality for atomic execution
 * of approve, swap, and metacall operations
 */
contract EIP7702SmartWallet {
    uint256 public nonce;
    mapping(address => bool) public authorizedImplementations;
    
    event ExecutionSuccess(bytes32 indexed operationHash, uint256 indexed nonce);
    event ImplementationAuthorized(address indexed implementation, bool authorized);
    
    error InvalidSignature();
    error UnauthorizedImplementation();
    error InvalidNonce();
    
    constructor() {
        // Initialize with nonce 0
        nonce = 0;
    }
    
    /**
     * @notice Authorize an implementation contract to execute on behalf of this wallet
     * @param implementation The address of the implementation contract
     * @param authorized Whether to authorize or revoke authorization
     */
    function authorizeImplementation(address implementation, bool authorized) external {
        // In a real implementation, this would be restricted to the wallet owner
        authorizedImplementations[implementation] = authorized;
        emit ImplementationAuthorized(implementation, authorized);
    }
    
    /**
     * @notice Execute a batch of operations atomically
     * @param calls Array of call data to execute
     * @param signature The signature authorizing this execution
     */
    function execute(CallData[] calldata calls, bytes calldata signature) external payable {
        // Verify the signature
        bytes32 operationHash = keccak256(abi.encodePacked(nonce, abi.encode(calls)));
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", operationHash));
        
        (bytes32 r, bytes32 s, uint8 v) = _splitSignature(signature);
        address signer = ecrecover(messageHash, v, r, s);
        
        // In a real implementation, verify the signer is authorized
        if (signer == address(0)) revert InvalidSignature();
        
        // Increment nonce to prevent replay attacks
        nonce++;
        
        // Execute all calls atomically
        for (uint256 i = 0; i < calls.length; i++) {
            CallData calldata call = calls[i];
            
            // Verify the target is an authorized implementation
            if (!authorizedImplementations[call.target]) revert UnauthorizedImplementation();
            
            // Execute the call
            (bool success, bytes memory result) = call.target.call{value: call.value}(call.data);
            require(success, "Call execution failed");
        }
        
        emit ExecutionSuccess(operationHash, nonce - 1);
    }
    
    /**
     * @notice Split signature into r, s, v components
     */
    function _splitSignature(bytes calldata signature) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "Invalid signature length");
        
        assembly {
            r := calldataload(add(signature.offset, 0x00))
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
    }
    
    // Fallback function to receive ETH
    receive() external payable {}
}

/**
 * @title CallData struct for EIP-7702 operations
 */
struct CallData {
    address target;
    uint256 value;
    bytes data;
}



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
    EIP7702SmartWallet smartWallet;

    address solverEOA;
    uint256 solverPK;

    address userEOA;
    uint256 userPK;

    address[] _path1 = new address[](2);
    address[] _path2 = new address[](2);
    uint256 amountIn = 0.1 ether;
    uint256 solverBidAmount = 15000 ether;
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
        
        // Set up reverse path for RARE to WETH swaps
        _path2[0] = rare;
        _path2[1] = weth;

        // Deploy EIP-7702 smart wallet
        vm.startPrank(userEOA);
        smartWallet = new EIP7702SmartWallet();
        
        // Authorize Atlas and Router for the smart wallet
        smartWallet.authorizeImplementation(address(ATLAS), true);
        smartWallet.authorizeImplementation(address(ROUTER), true);
        smartWallet.authorizeImplementation(weth, true);
        vm.stopPrank();
    }

    function test_EIP7702_AtomicBackrunWithMetacall() public {
        // Fund the smart wallet
        vm.deal(address(smartWallet), 10 ether);
        deal(weth, address(smartWallet), 1000 ether);
        
        // User wants to swap exact WETH for RARE (same logic as test_swapExactTokensForTokens)
        bytes memory swapData = abi.encodeWithSelector(
            0x38ed1739, // swapExactTokensForTokens selector
            amountIn,         // amountIn
            1,                // amountOutMin (low for testing)
            _path1,           // path
            address(smartWallet), // to (smart wallet receives the tokens)
            block.timestamp * 2 // deadline
        );

        address refundRecipient = makeAddr("REFUND_RECIPIENT");
        address bidToken = rare; // RARE is the bid token

        bytes memory userOpData = abi.encodeWithSelector(
            BackrunDAppControl.swap.selector,
            bidToken,
            refundRecipient,
            1000
        );

        uint256 msgValue = 0;

        // Build operations using the existing approach
        (UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) =
            buildOperations(userOpData, msgValue, bidToken);

        // Create the three operations for EIP-7702 atomic execution
        CallData[] memory calls = new CallData[](3);
        
        // Operation 1: Approve WETH for router
        calls[0] = CallData({
            target: weth,
            value: 0,
            data: abi.encodeWithSelector(IERC20.approve.selector, address(ROUTER), amountIn)
        });
        
        // Operation 2: Execute swap on router
        calls[1] = CallData({
            target: address(ROUTER),
            value: 0,
            data: swapData
        });
        
        // Operation 3: Execute metacall (solver operations only, no swap)
        calls[2] = CallData({
            target: address(ATLAS),
            value: msgValue,
            data: abi.encodeWithSelector(ATLAS.metacall.selector, userOp, solverOps, dAppOp, address(0))
        });
        
        // Sign the operation
        bytes32 operationHash = keccak256(abi.encodePacked(smartWallet.nonce(), abi.encode(calls)));
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", operationHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPK, messageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Record balances before execution
        uint256 smartWalletWethBefore = IERC20(weth).balanceOf(address(smartWallet));
        uint256 smartWalletRareBefore = IERC20(rare).balanceOf(address(smartWallet));
        
        // Execute the EIP-7702 atomic transaction
        vm.prank(userEOA);
        smartWallet.execute(calls, signature);
        
        // Verify the atomic execution was successful
        uint256 smartWalletWethAfter = IERC20(weth).balanceOf(address(smartWallet));
        uint256 smartWalletRareAfter = IERC20(rare).balanceOf(address(smartWallet));
        
        // Check that WETH was spent
        assertLt(smartWalletWethAfter, smartWalletWethBefore);
        
        // Check that RARE was received
        assertGt(smartWalletRareAfter, smartWalletRareBefore);
        
        // Verify nonce was incremented (replay protection)
        assertEq(smartWallet.nonce(), 1);
        
        console.log("EIP-7702 Atomic Backrun with Metacall successful!");
        console.log("WETH spent:", smartWalletWethBefore - smartWalletWethAfter);
        console.log("RARE received:", smartWalletRareAfter - smartWalletRareBefore);
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
            from: address(smartWallet),
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
        dAppOp.bundler = address(smartWallet);

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
        
        // Handle native token (ETH) differently from ERC20 tokens
        if (bidToken == NATIVE_TOKEN) {
            vm.deal(address(solver), bidAmount);
        } else {
            deal(bidToken, address(solver), bidAmount);
        }

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

    // Helper function to build solver operations for EIP-7702 tests
    function _buildSolverOperations() internal returns (SolverOperation[] memory) {
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        
        // Create a simple solver operation
        SolverOperation memory solverOp = txBuilder.buildSolverOperation({
            userOp: _buildUserOperation(),
            solverOpData: abi.encodeCall(SimpleSolver.solve, ()),
            solver: solverEOA,
            solverContract: address(_deploySimpleSolver()),
            bidAmount: solverBidAmount,
            value: 0
        });
        solverOp.bidToken = weth;
        solverOp.gas = solverGas;
        
        // Sign solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, ATLAS_VERIFICATION.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        
        solverOps[0] = solverOp;
        return solverOps;
    }
    
    function _buildUserOperation() internal view returns (UserOperation memory) {
        return txBuilder.buildUserOperation({
            from: address(smartWallet),
            to: payable(address(control)),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 20000,
            data: ""
        });
    }
    
    function _deploySimpleSolver() internal returns (SimpleSolver) {
        SimpleSolver solver = new SimpleSolver(weth, ATLAS_ADDRESS);
        deal(weth, address(solver), 100 ether);
        return solver;
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