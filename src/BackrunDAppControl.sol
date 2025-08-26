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
    uint32 internal constant DAPP_GAS_LIMIT = 10_000_000;
    address internal constant _ETH = address(0); // address of the ETH token

    uint256 public govPercent;
    address public govPayoutAddr;

    // Transient storage variables for refund handling
    address transient internal t_refundRecipient;
    uint256 transient internal t_refundPercent;
    address transient internal t_bidToken;
    // Add a new event to log bid token changes
    event GovernancePayoutAddressUpdated(address indexed oldGovPayoutAddr, address indexed newGovPayoutAddr);
    event GovernancePayoutSplitUpdated(uint256 oldPercentage, uint256 newPercentage);

    // allocate value hook events
    event UserPayout(address indexed user, uint256 amount, address bidToken);
    event GovernancePayout(address indexed govPayoutAddr, uint256 amount, address bidToken);

    event SwapSuccess(address indexed target, address indexed inputToken, address indexed outputToken, uint256 inputAmount, uint256 outputAmount);

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
        
        govPayoutAddr = _govPayoutAddr;
        emit GovernancePayoutAddressUpdated(govPayoutAddr, _govPayoutAddr);
    }

    /**
     * @notice Updates the governance percentage for bidAmount split
     * @param _govPercent The new governance percentage in basis points (0-10000)
     * @dev This function can only be called by the governance
     * @dev The governance percentage cannot exceed 100% (10000 basis points)
     */
    function setGovPercent(uint256 _govPercent) external onlyGovernance {
        require(_govPercent <= BPS_SCALE, GovPercentExceedsScale());
        
        govPercent = _govPercent;
        emit GovernancePayoutSplitUpdated(govPercent, _govPercent);
    }

    // ---------------------------------------------------- //
    //                  ENTRYPOINT FUNCTION                 //
    // ---------------------------------------------------- //

    /**
     * @notice Swaps tokens using the provided parameters
     * @param _bidToken The bid token address
     * @param _refundRecipient The address that will receive the refund
     * @param _refundPercent The percentage of the bid amount that goes to the refund recipient
     * @dev Entry point function does nothing, preOps call handles refund recipient
     */
    function swap(
        address _bidToken,
        address _refundRecipient,
        uint256 _refundPercent
    ) external payable { /* USEROP DOESNT DO ANYTHING */  }
    
    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        (address _bidToken, address _refundRecipient, uint256 _refundPercent) 
            = abi.decode(userOp.data[4:], (address, address, uint256));
        require(_refundPercent <= BPS_SCALE - 1000, GovPercentExceedsScale());

        _setRefundParams(_refundRecipient, _refundPercent);    

        return userOp.data[4:]; 
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata data) internal virtual override {
        (address _bidToken, , ) = abi.decode(data, (address, address, uint256));
        if (solverOp.bidToken != _bidToken) revert WrongBidToken();
    }

    function _allocateValueCall(bool, address _bidToken, uint256 bidAmount, bytes calldata) internal virtual override {
        (address _refundRecipient, uint256 _refundPercent) = _getRefundParams();
        (address _govPayoutAddr, uint256 _govPercent) = BackrunDAppControl(payable(CONTROL)).getPayoutData();
        require(_govPercent + _refundPercent <= BPS_SCALE, GovPercentExceedsScale());

        uint256 _bidTokenBalance = _balanceOf(address(this), _bidToken);
        require(_bidTokenBalance >= bidAmount, InsufficientOutputBalance());

        // Calculate governance, refund, and user amounts
        uint256 govPayoutAmount = (_bidTokenBalance * _govPercent) / BPS_SCALE;
        uint256 refundAmount = (_bidTokenBalance * _refundPercent) / BPS_SCALE;
        uint256 userAmount = _bidTokenBalance - govPayoutAmount - refundAmount;
        
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
        if (userAmount > 0) {
            _transferToken(_bidToken, _user(), userAmount);
            emit UserPayout(_user(), userAmount, _bidToken);
        }
    }

    // ---------------------------------------------------- //
    //                 GETTERS AND HELPERS                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public view virtual override returns (address) {
        (address _bidToken, , ) = abi.decode(userOp.data[4:], (address, address, uint256));
        return _bidToken;
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getPayoutData() public view returns (address, uint256) {
        return (govPayoutAddr, govPercent);
    }

    function getDAppGasLimit() public view virtual override returns (uint32) {
        return DAPP_GAS_LIMIT;
    }

    // Add fallback function to handle incoming ETH
    receive() external payable {}

    // ---------------------------------------------------- //
    //                    INTERNAL FUNCTIONS                //
    // ---------------------------------------------------- //

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
