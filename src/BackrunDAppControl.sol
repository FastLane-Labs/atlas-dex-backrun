//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { DAppControl } from "@atlas/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";

struct SwapTokenInfo {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputMin;
    bool bidTokenIsOutputToken;
    address target;
    bytes swapData;
}

contract BackrunDAppControl is DAppControl {
    uint256 internal constant BPS_SCALE = 10_000; //basis points denominator
    uint32 internal constant DAPP_GAS_LIMIT = 3_000_000;
    address internal constant _ETH = address(0); // address of the ETH token

    uint256 public govPercent;
    address public govPayoutAddr;

    // 0: not available
    // 1: transfer to EE and approve router
    // 2: transfer directly to router, no approval needed
    uint8 internal constant ROUTER_TYPE_NONE = 0;
    uint8 internal constant ROUTER_TYPE_APPROVE = 1;
    uint8 internal constant ROUTER_TYPE_DIRECT = 2;
    mapping(address => uint8) public routerWhitelist;

    // Transient storage variables for refund handling
    address internal transient t_refundRecipient;
    uint256 internal transient t_refundPercent;

    // Add a new event to log bid token changes
    event GovernancePayoutAddressUpdated(address indexed oldGovPayoutAddr, address indexed newGovPayoutAddr);
    event GovernancePayoutSplitUpdated(uint256 oldPercentage, uint256 newPercentage);

    // allocate value hook events
    event UserPayout(address indexed user, uint256 amount, address bidToken);
    event GovernancePayout(address indexed govPayoutAddr, uint256 amount, address bidToken);

    // router events
    event RouterAdded(address indexed router, uint8 routerType);
    event RouterRemoved(address indexed router);

    event SwapSuccess(
        address indexed target,
        address indexed inputToken,
        address indexed outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    );

    error InsufficientOutputBalance();
    error InsufficientUserOpValue();
    error InvalidRewardAddress();
    error InvalidUserOpData();
    error OnlyGovernance();
    error OnlyControl();
    error UserOpDappNotSwapRouter();
    error SwapFailed();
    error WrongBidToken();
    error GovPercentExceedsScale();
    error GovPayoutAddrZero();
    error InvalidRouterType();
    error RouterZeroAddress();

    /**
     * @notice Constructor for BackrunDAppControl
     *     @param _atlas The address of the Atlas contract
     *     @param _govPayoutAddr The address of the governance payout address
     *     @param _govPercent The percentage of the bid amount that goes to the governance payout address
     */
    constructor(
        address _atlas,
        address _govPayoutAddr,
        uint256 _govPercent
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: true,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                zeroSolvers: true,
                reuseUserOp: true,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: true,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                multipleSuccessfulSolvers: false,
                checkMetacallGasLimit: false
            })
        )
    {
        require(_govPayoutAddr != address(0), GovPayoutAddrZero());

        // Set bidToken to constant ETH if zero address
        govPayoutAddr = _govPayoutAddr;
        emit GovernancePayoutAddressUpdated(address(0), _govPayoutAddr);

        // Initialize governance percentage
        require(_govPercent <= BPS_SCALE, GovPercentExceedsScale());
        govPercent = _govPercent;
        emit GovernancePayoutSplitUpdated(0, _govPercent);
    }

    // ---------------------------------------------------- //
    //                     DAPP SETTERS                     //
    // ---------------------------------------------------- //

    /**
     * @notice Sets the reward address for the contract
     * @param _govPayoutAddr The new reward address
     * @dev This function can only be called by the governance
     * @dev The zero address (address(0)) is not allowed as a reward address
     */
    function setGovPayoutAddr(address _govPayoutAddr) external onlyGovernance {
        require(_govPayoutAddr != address(0), GovPayoutAddrZero());

        emit GovernancePayoutAddressUpdated(govPayoutAddr, _govPayoutAddr);
        govPayoutAddr = _govPayoutAddr;
    }

    /**
     * @notice Updates the governance percentage for bidAmount split
     * @param _govPercent The new governance percentage in basis points (0-10000)
     * @dev This function can only be called by the governance
     * @dev The governance percentage cannot exceed 100% (10000 basis points)
     */
    function setGovPercent(uint256 _govPercent) external onlyGovernance {
        require(_govPercent <= BPS_SCALE, GovPercentExceedsScale());
        emit GovernancePayoutSplitUpdated(govPercent, _govPercent);
        govPercent = _govPercent;
    }

    /**
     * @notice Adds a router to the whitelist
     * @param _router The address of the router to add to the whitelist
     * @param _type The router type (1: approve, 2: direct)
     * @dev This function can only be called by the governance
     */
    function addRouter(address _router, uint8 _type) external onlyGovernance {
        require(_type == ROUTER_TYPE_APPROVE || _type == ROUTER_TYPE_DIRECT, InvalidRouterType());
        require(_router != address(0), RouterZeroAddress());
        routerWhitelist[_router] = _type;
        emit RouterAdded(_router, _type);
    }

    /**
     * @notice Removes a router from the whitelist
     * @param _router The address of the router to remove from the whitelist
     * @dev This function can only be called by the governance
     */
    function removeRouter(address _router) external onlyGovernance {
        routerWhitelist[_router] = ROUTER_TYPE_NONE;
        emit RouterRemoved(_router);
    }

    // ---------------------------------------------------- //
    //                  ENTRYPOINT FUNCTION                 //
    // ---------------------------------------------------- //

    /**
     * @notice Swaps tokens using the provided swap info
     * @param _swapInfo The swap info containing the input token, input amount, output token, output min, and target
     * @param _refundRecipient The address that will receive the refund
     * @param _refundPercent The percentage of the bid amount that goes to the refund recipient
     * @dev Entry point function handles ETH swaps and preOps call handles erc20 swaps
     */
    function swap(SwapTokenInfo calldata _swapInfo, address _refundRecipient, uint256 _refundPercent) external payable {
        // If the input token is ETH, call the swap function with msg.value
        if (_swapInfo.inputToken == _ETH) {
            require(msg.value == _swapInfo.inputAmount, InsufficientUserOpValue());

            _executeSwap(
                _swapInfo.target,
                _ETH,
                _swapInfo.outputToken,
                _swapInfo.inputAmount,
                _swapInfo.outputMin,
                _swapInfo.swapData,
                _user()
            );
        }
    }

    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        (SwapTokenInfo memory _swapInfo, address _refundRecipient, uint256 _refundPercent) =
            abi.decode(userOp.data[4:], (SwapTokenInfo, address, uint256));
        require(_refundPercent <= BPS_SCALE - 1000, GovPercentExceedsScale());

        _setRefundParams(_refundRecipient, _refundPercent);

        uint8 _routerWhitelist = BackrunDAppControl(payable(CONTROL)).isRouterWhitelisted(_swapInfo.target);
        require(_routerWhitelist != ROUTER_TYPE_NONE, UserOpDappNotSwapRouter());

        // If inputToken is ERC20, transfer tokens from user to EE, and approve router for swap
        if (_swapInfo.inputToken != _ETH) {
            if (_routerWhitelist == ROUTER_TYPE_APPROVE) {
                _transferUserERC20(_swapInfo.inputToken, address(this), _swapInfo.inputAmount);
                SafeTransferLib.safeApprove(_swapInfo.inputToken, _swapInfo.target, _swapInfo.inputAmount);
            } else if (_routerWhitelist == ROUTER_TYPE_DIRECT) {
                _transferUserERC20(_swapInfo.inputToken, _swapInfo.target, _swapInfo.inputAmount);
            } else {
                revert UserOpDappNotSwapRouter();
            }

            _executeSwap(
                _swapInfo.target,
                _swapInfo.inputToken,
                _swapInfo.outputToken,
                _swapInfo.inputAmount,
                _swapInfo.outputMin,
                _swapInfo.swapData,
                userOp.from
            );
        }

        return userOp.data[4:];
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata data) internal virtual override {
        (SwapTokenInfo memory _swapInfo,,) = abi.decode(data, (SwapTokenInfo, address, uint256));
        if (solverOp.bidToken != _swapInfo.outputToken) revert WrongBidToken();
    }

    function _allocateValueCall(
        bool solverSuccess,
        address _bidToken,
        uint256 bidAmount,
        bytes calldata
    )
        internal
        virtual
        override
    {
        (address _refundRecipient, uint256 _refundPercent) = _getRefundParams();
        (address _govPayoutAddr, uint256 _govPercent) = BackrunDAppControl(payable(CONTROL)).getPayoutData();
        require(_govPercent + _refundPercent <= BPS_SCALE, GovPercentExceedsScale());

        if (_refundPercent > 0) {
            require(_refundRecipient != address(0), InvalidRewardAddress());
        }

        uint256 _outputTokenBalance = _balanceOf(address(this), _bidToken);
        require(_outputTokenBalance >= bidAmount, InsufficientOutputBalance());

        // Calculate governance, refund, and user amounts
        uint256 govPayoutAmount = (bidAmount * _govPercent) / BPS_SCALE;
        uint256 refundAmount = (bidAmount * _refundPercent) / BPS_SCALE;
        uint256 userAmount = bidAmount - govPayoutAmount - refundAmount;

        uint256 residual = _outputTokenBalance - bidAmount;

        // Transfer governance amount to payout address if not zero
        if (govPayoutAmount > 0) {
            _transferToken(_bidToken, _govPayoutAddr, govPayoutAmount);
            emit GovernancePayout(_govPayoutAddr, govPayoutAmount, _bidToken);
        }

        // Transfer refund amount if not zero
        if (refundAmount > 0 && _refundRecipient != address(0)) {
            _transferToken(_bidToken, _refundRecipient, refundAmount);
            emit UserPayout(_refundRecipient, refundAmount, _bidToken);
        }

        //Transfer user tokens to user
        uint256 userTotal = userAmount + residual;
        if (userTotal > 0) {
            _transferToken(_bidToken, _user(), userTotal);
            emit UserPayout(_user(), userTotal, _bidToken);
        }
    }

    // ---------------------------------------------------- //
    //                 GETTERS AND HELPERS                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public view virtual override returns (address) {
        (SwapTokenInfo memory _swapInfo,,) = abi.decode(userOp.data[4:], (SwapTokenInfo, address, uint256));
        return _swapInfo.bidTokenIsOutputToken ? _swapInfo.outputToken : _ETH;
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getPayoutData() public view returns (address, uint256) {
        return (govPayoutAddr, govPercent);
    }

    function isRouterWhitelisted(address _router) public view returns (uint8) {
        return routerWhitelist[_router];
    }

    function getDAppGasLimit() public view virtual override returns (uint32) {
        return DAPP_GAS_LIMIT;
    }

    // Add fallback function to handle incoming ETH
    receive() external payable { }

    // ---------------------------------------------------- //
    //                    INTERNAL FUNCTIONS                //
    // ---------------------------------------------------- //

    function _executeSwap(
        address target,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputMin,
        bytes memory swapData,
        address user
    )
        internal
        returns (uint256 amountOut)
    {
        uint256 outputTokenBalanceBefore = _balanceOf(user, outputToken);

        (bool success,) = target.call{ value: inputToken == _ETH ? inputAmount : 0 }(swapData);
        require(success, SwapFailed());

        uint256 eeBalance = _balanceOf(address(this), outputToken);
        if (eeBalance > 0) {
            _transferToken(outputToken, user, eeBalance);
        }

        uint256 outputTokenBalanceAfter = _balanceOf(user, outputToken);
        amountOut = outputTokenBalanceAfter - outputTokenBalanceBefore;
        require(amountOut >= outputMin, InsufficientOutputBalance());

        emit SwapSuccess(target, inputToken, outputToken, inputAmount, amountOut);
    }

    function _balanceOf(address _user, address token) internal view returns (uint256) {
        if (token == _ETH) {
            return _user.balance;
        } else {
            return SafeTransferLib.balanceOf(token, _user);
        }
    }

    function _transferToken(address _token, address _to, uint256 _amount) internal {
        if (_token == _ETH) {
            SafeTransferLib.safeTransferETH(_to, _amount);
        } else {
            SafeTransferLib.safeTransfer(_token, _to, _amount);
        }
    }

    function _setRefundParams(address _refundRecipient, uint256 _refundPercent) internal {
        t_refundRecipient = _refundRecipient;
        t_refundPercent = _refundPercent;
    }

    function _getRefundParams() internal view returns (address, uint256) {
        return (t_refundRecipient, t_refundPercent);
    }

    // ---------------------------------------------------- //
    //                    Modifiers                         //
    // ---------------------------------------------------- //

    modifier onlyGovernance() {
        require(msg.sender == governance, OnlyGovernance());
        require(address(this) == CONTROL, OnlyControl());
        _;
    }
}
