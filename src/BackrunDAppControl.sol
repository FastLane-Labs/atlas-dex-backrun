//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DAppControl } from "@atlas/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";

import { SwapMath } from "./SwapMath.sol";

import "forge-std/Test.sol";

struct SwapTokenInfo {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputMin;
    address target;
    bytes swapData;
}

contract BackrunDAppControl is DAppControl {
    uint256 public constant PERCENTAGE_DENOMINATOR = 10_000; //basis points denominator
    uint32 public constant SOLVER_GAS_LIMIT = 1_000_000;
    uint32 public constant DAPP_GAS_LIMIT = 500_000;
    address internal constant _ETH = address(0); // address of the ETH token

    uint256 public govPercent;
    address public govPayoutAddr;
    mapping(address => bool) public routerWhitelist;

    // Add a new event to log bid token changes
    event GovernancePayoutAddressUpdated(address indexed oldGovPayoutAddr, address indexed newGovPayoutAddr);
    event GovernancePayoutSplitUpdated(uint256 oldPercentage, uint256 newPercentage);

    // allocate value hook events
    event UserPayout(address indexed user, uint256 amount);
    event GovernancePayout(address indexed govPayoutAddr, uint256 amount);

    error InsufficientOutputBalance();
    error InsufficientUserOpValue();
    error InvalidRewardAddress();
    error InvalidUserOpData();
    error OnlyGovernance();
    error UserOpDappNotSwapRouter();
    error SwapFailed();
    error WrongBidToken();

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
                reuseUserOp: true,
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

        // Initialize governance percentage
        require(_govPercent <= PERCENTAGE_DENOMINATOR, "Governance percentage cannot exceed 100%");
        govPercent = _govPercent;
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
        require(_govPayoutAddr != govPayoutAddr, "Governance payout address is already set");
        require(_govPayoutAddr != address(0), "Governance address cannot be zero");
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
        require(_govPercent <= PERCENTAGE_DENOMINATOR, "Governance percentage cannot exceed 100%");
        require(_govPercent != govPercent, "New percentage must be different");

        emit GovernancePayoutSplitUpdated(govPercent, _govPercent);
        govPercent = _govPercent;
    }

    /**
     * @notice Adds a router to the whitelist
     * @param _router The address of the router to add to the whitelist
     * @dev This function can only be called by the governance
     */
    function addRouter(address _router) external onlyGovernance {
        routerWhitelist[_router] = true;
    }

    /**
     * @notice Removes a router from the whitelist
     * @param _router The address of the router to remove from the whitelist
     * @dev This function can only be called by the governance
     */
    function removeRouter(address _router) external onlyGovernance {
        routerWhitelist[_router] = false;
    }

    // ---------------------------------------------------- //
    //                  ENTRYPOINT FUNCTION                 //
    // ---------------------------------------------------- //

    /**
     * @notice Swaps tokens using the provided swap info
     * @param _swapInfo The swap info containing the input token, input amount, output token, output min, and target
     * @dev This function is only callable by the DAppControl
     */
    function swap(SwapTokenInfo memory _swapInfo) external payable {
        SafeTransferLib.safeTransferFrom(_swapInfo.inputToken, msg.sender, address(this), _swapInfo.inputAmount);
        SafeTransferLib.safeApprove(_swapInfo.inputToken, _swapInfo.target, _swapInfo.inputAmount);
        (bool success, bytes memory _returnData) = _swapInfo.target.call{value: msg.value}(_swapInfo.swapData);
        if (!success) revert SwapFailed();
    }

    
    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        SwapTokenInfo memory _swapInfo = abi.decode(userOp.data[4:], (SwapTokenInfo));

        // Transfer bid token to governance payout address
        (bool success, bytes memory data) =
            CONTROL.staticcall(abi.encodeWithSelector(this.isRouterWhitelisted.selector, _swapInfo.target));
        bool _routerWhitelist = abi.decode(data, (bool));
        if (!_routerWhitelist) revert UserOpDappNotSwapRouter();

        // If inputToken is ERC20, transfer tokens from user to EE, and approve router for swap
        if (userOp.value < _swapInfo.inputAmount) {
            if (_swapInfo.inputToken != _ETH) {
                _transferUserERC20(_swapInfo.inputToken, address(this), _swapInfo.inputAmount);
                SafeTransferLib.safeApprove(_swapInfo.inputToken, CONTROL, _swapInfo.inputAmount);
                
            } else {
                revert InsufficientUserOpValue();
            }
        }

        return userOp.data[4:]; // return SwapTokenInfo in bytes format, to be used in allocateValue.
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata data) internal virtual override {
        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));
        if (solverOp.bidToken != _swapInfo.outputToken) revert WrongBidToken();
    }

    function _allocateValueCall(bool, address _bidToken, uint256 bidAmount, bytes calldata data) internal virtual override {
        // Decode the swap info from the data
        SwapTokenInfo memory _swapInfo = abi.decode(data, (SwapTokenInfo));

        uint256 _outputTokenBalance = _balanceOf(_swapInfo.outputToken);
        if (_outputTokenBalance < _swapInfo.outputMin) revert InsufficientOutputBalance();

        // Transfer bid token to governance payout address
        (bool success, bytes memory _payoutData) =
            CONTROL.staticcall(abi.encodeWithSelector(this.getPayoutData.selector));

        if (!success || data.length == 0) revert InvalidRewardAddress();
        (address _govPayoutAddr, uint256 _govPercent) = abi.decode(_payoutData, (address, uint256));

        // Calculate governance and user amounts and split the bidAmount
        uint256 govPayoutAmount = (bidAmount * _govPercent) / PERCENTAGE_DENOMINATOR;
        console.log("govPayoutAmount", govPayoutAmount);
        uint256 userAmount = _outputTokenBalance - govPayoutAmount;
        console.log("userAmount", userAmount);
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
        emit UserPayout(_user(), userAmount);
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
        address _dAppGov = BackrunDAppControl(this).getDAppSignatory();
        if (msg.sender != _dAppGov) revert OnlyGovernance();
        _;
    }
}
