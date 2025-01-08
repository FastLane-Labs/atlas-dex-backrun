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

contract UniswapV3Test is BaseTest {
    uint24[] _fees = new uint24[](2);
    address[] _tokens = new address[](3);

    address weth_usdc_pool = FACTORY.getPool(WETH_ADDRESS_BASE, USDC_ADDRESS_BASE, _fees[0]);
    address usdc_cbbtc_pool = FACTORY.getPool(USDC_ADDRESS_BASE, CBBTC_ADDRESS_BASE, _fees[1]);

    uint24 FEE = 80;
    address weth_cbbtc_pool = FACTORY.getPool(WETH_ADDRESS_BASE, CBBTC_ADDRESS_BASE, FEE);

    uint256 amountIn = 1 ether;
    uint256 amountOut = 3_600_000;
    uint256 amountInMax = 1 ether;
    address tokenIn = WETH_ADDRESS_BASE;
    address tokenOut = CBBTC_ADDRESS_BASE;
    uint256 bundlerGasEth = 1e16;

    Sig sig;

    function setUp() public virtual override {
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        _fees[0] = 80;
        _fees[1] = 350;

        _tokens[0] = WETH_ADDRESS_BASE;
        _tokens[1] = USDC_ADDRESS_BASE;
        _tokens[2] = CBBTC_ADDRESS_BASE;

        deal(userEOA, 1 ether);
        deal(tokenIn, userEOA, amountIn);
        deal(tokenOut, userEOA, amountOut);
    }

    function testUniswapV3Swaps() public {
        deal(address(this), amountIn);

        // exactInputSingleNativeToken
        ISwapRouter.ExactInputSingleParams memory paramsInputSingleNative = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOutInputSingleNative = ROUTER.exactInputSingle{ value: amountIn }(paramsInputSingleNative);
        console.log("Native ETH SWAP TO cbBTC", amountOutInputSingleNative);

        deal(WETH_ADDRESS_BASE, address(this), 10e18);
        deal(CBBTC_ADDRESS_BASE, address(this), amountOut);

        // exactOutputMulti
        WETH_BASE.approve(address(ROUTER), amountInMax);

        ISwapRouter.ExactOutputParams memory paramsOutputMulti = ISwapRouter.ExactOutputParams({
            path: encodePath(_tokens, _fees, true),
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: amountInMax
        });

        uint256 amountInOuputMulti = ROUTER.exactOutput(paramsOutputMulti);
        console.log(amountInOuputMulti);

        // exactInputMulti
        WETH_BASE.approve(address(ROUTER), amountIn);

        ISwapRouter.ExactInputParams memory paramsInputMulti = ISwapRouter.ExactInputParams({
            path: encodePath(_tokens, _fees, false),
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0
        });

        uint256 amountOutInputMulti = ROUTER.exactInput(paramsInputMulti);
        console.log(amountOutInputMulti);

        // exactOutputSingle
        WETH_BASE.approve(address(ROUTER), amountInMax);

        ISwapRouter.ExactOutputSingleParams memory paramsOutputSingle = ISwapRouter.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: amountOut,
            amountInMaximum: amountInMax,
            sqrtPriceLimitX96: 0
        });

        uint256 amountInOutputSingle = ROUTER.exactOutputSingle(paramsOutputSingle);
        console.log(amountInOutputSingle);

        // exactInputSingle
        WETH_BASE.approve(address(ROUTER), amountIn);

        ISwapRouter.ExactInputSingleParams memory paramsInputSingle = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: FEE,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOutInputSingle = ROUTER.exactInputSingle(paramsInputSingle);
        console.log("CBBTC", amountOutInputSingle);

        // multicall
        uint256 amountOutMulticallBefore = _balanceOf(address(0), msg.sender);

        CBBTC_BASE.approve(address(ROUTER), amountOut);

        bool outputIsWETH = true;

        ISwapRouter.ExactInputParams memory paramsMulticall = ISwapRouter.ExactInputParams({
            path: encodePath(_tokens, _fees, true),
            recipient: outputIsWETH ? address(0) : msg.sender,
            deadline: block.timestamp,
            amountIn: amountOut,
            amountOutMinimum: 0
        });

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(ROUTER.exactInput.selector, paramsMulticall);
        data[1] = abi.encodeWithSelector(ROUTER.unwrapWETH9.selector, 0, address(msg.sender));

        ROUTER.multicall(data);

        uint256 amountOutMulticallAfter = _balanceOf(address(0), msg.sender);
        console.log(amountOutMulticallAfter - amountOutMulticallBefore);
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
}
