//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DAppControl } from "@atlas/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";

import { SwapMath } from "./SwapMath.sol";

struct SwapTokenInfo {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputMin;
    address target;
    bytes swapData;
}

contract BackrunDAppControl is DAppControl {
    uint256 internal constant BPS_SCALE = 10_000; //basis points denominator
    uint32 internal constant SOLVER_GAS_LIMIT = 1_000_000;
    uint32 internal constant DAPP_GAS_LIMIT = 500_000;
    address internal constant _ETH = address(0); // address of the ETH token

    uint256 public govPercent;
    address public govPayoutAddr;
    mapping(address => bool) public routerWhitelist;

    // Add a new event to log bid token changes
    event GovernancePayoutAddressUpdated(address indexed oldGovPayoutAddr, address indexed newGovPayoutAddr);
    event GovernancePayoutSplitUpdated(uint256 oldPercentage, uint256 newPercentage);

    // allocate value hook events
    event UserPayout(address indexed user, uint256 amount, address bidToken);
    event GovernancePayout(address indexed govPayoutAddr, uint256 amount);

    // router events
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);

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
     * @notice Constructor for UniswapV2DAppControl
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
                reuseUserOp: false,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: true,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false // NOTE: allow solver to set bidAmount after onchain bid-finding
                // allowAllocateValueFailure: false
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

    /**
     * @notice Adds a router to the whitelist
     * @param _router The address of the router to add to the whitelist
     * @dev This function can only be called by the governance
     */
    function addRouter(address _router) external onlyGovernance {
        routerWhitelist[_router] = true;
        emit RouterAdded(_router);
    }

    /**
     * @notice Removes a router from the whitelist
     * @param _router The address of the router to remove from the whitelist
     * @dev This function can only be called by the governance
     */
    function removeRouter(address _router) external onlyGovernance {
        routerWhitelist[_router] = false;
        emit RouterRemoved(_router);
    }

    // ---------------------------------------------------- //
    //                  ENTRYPOINT FUNCTION                 //
    // ---------------------------------------------------- //

    /**
     * @notice Swaps tokens using the provided swap info
     * @param _swapInfo The swap info containing the input token, input amount, output token, output min, and target
     * @dev Entry point function doesn't do anything, call is made in preOpsCall
     */
    function swap(SwapTokenInfo memory _swapInfo) external payable {}

    
    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        SwapTokenInfo memory _swapInfo = abi.decode(userOp.data[4:], (SwapTokenInfo));

        bool _routerWhitelist = BackrunDAppControl(CONTROL).isRouterWhitelisted(_swapInfo.target); 
        require(_routerWhitelist, UserOpDappNotSwapRouter());

        // If inputToken is ERC20, transfer tokens from user to EE, and approve router for swap
        if (userOp.value < _swapInfo.inputAmount) {
            if (_swapInfo.inputToken != _ETH) {
                _transferUserERC20(_swapInfo.inputToken, address(this), _swapInfo.inputAmount);
                SafeTransferLib.safeApprove(_swapInfo.inputToken, _swapInfo.target, _swapInfo.inputAmount);
            } else {
                revert InsufficientUserOpValue();
            }    
        }

        (bool success, ) = _swapInfo.target.call{value: msg.value}(_swapInfo.swapData);
        require(success, SwapFailed());

        uint256 _outputTokenBalance = _balanceOf(_swapInfo.outputToken);
        require(_outputTokenBalance >= _swapInfo.outputMin, InsufficientOutputBalance());

        return userOp.data[4:]; // return SwapTokenInfo in bytes format, to be used in allocateValue.
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata data) internal virtual override {
        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));
        if (solverOp.bidToken != _swapInfo.outputToken) revert WrongBidToken();
    }

    function _allocateValueCall(bool, address _bidToken, uint256 bidAmount, bytes calldata data) internal virtual override {
        // Decode the swap info from the data
        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));

        (address _govPayoutAddr, uint256 _govPercent) = BackrunDAppControl(CONTROL).getPayoutData();

        uint256 _outputTokenBalance = _balanceOf(_swapInfo.outputToken);
        require(_outputTokenBalance >= _swapInfo.outputMin, InsufficientOutputBalance());

        // Calculate governance and user amounts and split the bidAmount
        uint256 govPayoutAmount = (bidAmount * _govPercent) / BPS_SCALE;
        uint256 userAmount = _outputTokenBalance - govPayoutAmount;
        
        // Transfer governance amount to payout address if not zero
        if (govPayoutAmount > 0) {
            if (_bidToken == _ETH) {
                SafeTransferLib.safeTransferETH(_govPayoutAddr, govPayoutAmount);
            } else {
                SafeTransferLib.safeTransfer(_bidToken, _govPayoutAddr, govPayoutAmount);
            }
            emit GovernancePayout(_govPayoutAddr, govPayoutAmount);
        }

        //Transfer user tokens to user 
        if (_bidToken == _ETH) {
            SafeTransferLib.safeTransferETH(_user(), userAmount);
        } else {
            SafeTransferLib.safeTransfer(_bidToken, _user(), userAmount);
        }
        emit UserPayout(_user(), bidAmount, _bidToken);
    }

    // ---------------------------------------------------- //
    //                 GETTERS AND HELPERS                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata userOp) public view virtual override returns (address) {
        SwapTokenInfo memory _swapInfo = abi.decode(userOp.data[4:], (SwapTokenInfo));
        return _swapInfo.outputToken;
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getSolverGasLimit() public view virtual override returns (uint32) {
        return SOLVER_GAS_LIMIT;
    }

    function getDAppGasLimit() public view virtual override returns (uint32) {
        return DAPP_GAS_LIMIT;
    }

    function getPayoutData() public view returns (address, uint256) {
        return (govPayoutAddr, govPercent);
    }

    function isRouterWhitelisted(address _router) public view returns (bool) {
        return routerWhitelist[_router];
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == _ETH) {
            return address(this).balance;
        } else {
            return SafeTransferLib.balanceOf(token, address(this));
        }
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
