// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { BackrunDAppControl } from "../src/BackrunDAppControl.sol";
import { TestToken } from "./helpers/TestToken.sol";

contract BackrunDAppControlTest is Test {
    uint256 private constant GOV_PERCENT_BPS = 1_000; // 10%
    uint256 private constant REFUND_PERCENT_BPS = 1_000; // 10%
    uint256 private constant BID_AMOUNT = 1_500 ether;

    address private constant DEPLOYER_PK_ADDR = address(0xa11ce);
    address private constant USER_ADDR = address(0xc0ffee);
    address private constant REFUND_ADDR = address(0xB0B);

    address private atlasAddress;

    BackrunDAppControlHarness internal harness;
    TestToken internal bidToken;

    function setUp() public {
        string memory rpcUrl = vm.envString("MONAD_RPC_URL");
        vm.createSelectFork(rpcUrl);

        atlasAddress = vm.envAddress("ATLAS_ADDRESS");

        vm.deal(DEPLOYER_PK_ADDR, 0);
        vm.deal(USER_ADDR, 0);
        vm.deal(REFUND_ADDR, 0);

        vm.startPrank(DEPLOYER_PK_ADDR);
        harness = new BackrunDAppControlHarness(atlasAddress, DEPLOYER_PK_ADDR, GOV_PERCENT_BPS);
        vm.stopPrank();

        bidToken = new TestToken("Bid", "BID");
    }

    function test_constructor_revertsWhenGovAddressZero() public {
        vm.expectRevert(BackrunDAppControl.GovPayoutAddrZero.selector);
        new BackrunDAppControlHarness(atlasAddress, address(0), GOV_PERCENT_BPS);
    }

    function test_setGovPayoutAddr_emitsOldAndNewValues() public {
        address newGov = address(0xBEEF);

        vm.startPrank(DEPLOYER_PK_ADDR);
        vm.expectEmit(true, true, false, true, address(harness));
        emit BackrunDAppControl.GovernancePayoutAddressUpdated(DEPLOYER_PK_ADDR, newGov);
        harness.setGovPayoutAddr(newGov);
        vm.stopPrank();

        assertEq(harness.govPayoutAddr(), newGov);
    }

    function test_setGovPercent_emitsOldAndNewValues() public {
        uint256 newPercent = 2_000;

        vm.startPrank(DEPLOYER_PK_ADDR);
        vm.expectEmit(false, false, false, true, address(harness));
        emit BackrunDAppControl.GovernancePayoutSplitUpdated(GOV_PERCENT_BPS, newPercent);
        harness.setGovPercent(newPercent);
        vm.stopPrank();

        assertEq(harness.govPercent(), newPercent);
    }

    function test_allocateValueCall_distributesErc20() public {
        uint256 residual = 100 ether;
        bidToken.mint(address(harness), BID_AMOUNT + residual);

        uint256 govBefore = bidToken.balanceOf(harness.govPayoutAddr());
        uint256 refundBefore = bidToken.balanceOf(REFUND_ADDR);
        uint256 userBefore = bidToken.balanceOf(USER_ADDR);

        (bool success, bytes memory returnData) = _callWithAtlasContext(
            abi.encodeWithSelector(
                harness.callAllocateValue.selector,
                address(bidToken),
                BID_AMOUNT,
                REFUND_ADDR,
                REFUND_PERCENT_BPS,
                bytes("")
            )
        );
        _rethrowIfFailed(success, returnData);

        uint256 expectedGov = (BID_AMOUNT * GOV_PERCENT_BPS) / 10_000;
        uint256 expectedRefund = (BID_AMOUNT * REFUND_PERCENT_BPS) / 10_000;
        uint256 expectedUser = BID_AMOUNT - expectedGov - expectedRefund + residual;

        assertEq(bidToken.balanceOf(harness.govPayoutAddr()) - govBefore, expectedGov, "gov share");
        assertEq(bidToken.balanceOf(REFUND_ADDR) - refundBefore, expectedRefund, "refund share");
        assertEq(bidToken.balanceOf(USER_ADDR) - userBefore, expectedUser, "user share");
        assertEq(bidToken.balanceOf(address(harness)), 0, "harness drained");
    }

    function test_allocateValueCall_distributesNative() public {
        uint256 residual = 1 ether;
        vm.deal(address(harness), BID_AMOUNT + residual);

        uint256 govBefore = harness.govPayoutAddr().balance;
        uint256 refundBefore = REFUND_ADDR.balance;
        uint256 userBefore = USER_ADDR.balance;

        (bool success, bytes memory returnData) = _callWithAtlasContext(
            abi.encodeWithSelector(
                harness.callAllocateValue.selector,
                address(0),
                BID_AMOUNT,
                REFUND_ADDR,
                REFUND_PERCENT_BPS,
                bytes("")
            )
        );
        _rethrowIfFailed(success, returnData);

        uint256 expectedGov = (BID_AMOUNT * GOV_PERCENT_BPS) / 10_000;
        uint256 expectedRefund = (BID_AMOUNT * REFUND_PERCENT_BPS) / 10_000;
        uint256 expectedUser = BID_AMOUNT - expectedGov - expectedRefund + residual;

        assertEq(harness.govPayoutAddr().balance - govBefore, expectedGov, "gov share");
        assertEq(REFUND_ADDR.balance - refundBefore, expectedRefund, "refund share");
        assertEq(USER_ADDR.balance - userBefore, expectedUser, "user share");
        assertEq(address(harness).balance, 0, "harness drained");
    }

    function test_allocateValueCall_revertsWhenRefundRecipientMissing() public {
        vm.deal(address(harness), BID_AMOUNT);

        (bool success, bytes memory returnData) = _callWithAtlasContext(
            abi.encodeWithSelector(
                harness.callAllocateValue.selector,
                address(0),
                BID_AMOUNT,
                address(0),
                REFUND_PERCENT_BPS,
                bytes("")
            )
        );

        assertFalse(success, "call should revert");
        assertEq(bytes4(returnData), BackrunDAppControl.InvalidRewardAddress.selector, "unexpected revert");
    }

    function _callWithAtlasContext(bytes memory data) internal returns (bool success, bytes memory returnData) {
        bytes memory context = abi.encodePacked(USER_ADDR, address(harness), harness.CALL_CONFIG());
        vm.prank(atlasAddress);
        (success, returnData) = address(harness).call(bytes.concat(data, context));
    }

    function _rethrowIfFailed(bool success, bytes memory returnData) internal pure {
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

contract BackrunDAppControlHarness is BackrunDAppControl {
    constructor(address atlas, address govPayoutAddr, uint256 govPercent)
        BackrunDAppControl(atlas, govPayoutAddr, govPercent)
    {}

    function callAllocateValue(
        address bidToken,
        uint256 bidAmount,
        address refundRecipient,
        uint256 refundPercent,
        bytes calldata payload
    ) external {
        _setRefundParams(refundRecipient, refundPercent);
        require(t_refundPercent == refundPercent, "refund percent unset");
        require(t_refundRecipient == refundRecipient, "refund recipient unset");
        _allocateValueCall(true, bidToken, bidAmount, payload);
    }
}
