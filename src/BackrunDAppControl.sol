//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IShMonad } from "./interfaces/IShMonad.sol";
import { IAtlas } from "@atlas/interfaces/IAtlas.sol";

import { DAppControl } from "@atlas/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/types/UserOperation.sol";
import { SolverOperation } from "@atlas/types/SolverOperation.sol";

import { SwapMath } from "./SwapMath.sol";

import "forge-std/console.sol";

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
    uint32 internal constant SOLVER_GAS_LIMIT = 1_000_000;
    uint32 internal constant DAPP_GAS_LIMIT = 500_000;
    address internal constant _ETH = address(0); // address of the ETH token
    address internal constant _WETH = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701; // address of the WETH token

    uint256 public govPercent;
    address public govPayoutAddr;
    uint64 public policyId;
    mapping(address => bool) public routerWhitelist;

    IShMonad public immutable shMonad;

    // Transient storage variables for refund handling
    address transient internal t_refundRecipient;
    uint256 transient internal t_refundPercent;
    uint256 transient internal t_gasLimit;
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
     *     @param _shMonad The address of the shMonad contract
     *     @param _atlas The address of the Atlas contract
     *     @param _govPayoutAddr The address of the governance payout address
     *     @param _govPercent The percentage of the bid amount that goes to the governance payout address
     *     @param _policyId The policy id of the shMonad contract
     */
    constructor(
        address _shMonad,
        address _atlas,
        address _govPayoutAddr,
        uint256 _govPercent,
        uint64 _policyId
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
                exPostBids: false,
                multipleSuccessfulSolvers: false
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

        policyId = _policyId;
        shMonad = IShMonad(_shMonad);
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

    /**
     * @notice Transfers the ownership of the agent to a new address
     * @param _newOwner The address to transfer the ownership to
     * @dev This function can only be called by the governance
     */
    function transferAgentOwnership(address _newOwner) external onlyGovernance {
        shMonad.transferOwnership(_newOwner);
    }

    // ---------------------------------------------------- //
    //                  ENTRYPOINT FUNCTION                 //
    // ---------------------------------------------------- //

    /**
     * @notice Swaps tokens using the provided swap info
     * @param _swapInfo The swap info containing the input token, input amount, output token, output min, and target
     * @param _refundRecipient The address that will receive the refund
     * @param _refundPercent The percentage of the bid amount that goes to the refund recipient
     * @dev Entry point function doesn't do anything, call is made in preOpsCall
     */
    function swap(
        SwapTokenInfo calldata _swapInfo,
        address _refundRecipient,
        uint256 _refundPercent
        // uint256 _gasLimit
    ) external payable {
        IAtlas atlas = IAtlas(ATLAS);
        (address executionEnvironment, , bool exists) = atlas.getExecutionEnvironment(_user(), CONTROL);

        if (msg.sender == executionEnvironment && exists) {
            uint64 _policyId = BackrunDAppControl(payable(CONTROL)).getPolicyId();
            (address _govPayoutAddr, ) = BackrunDAppControl(payable(CONTROL)).getPayoutData();
            
            // If the gov payout addr has bonded shares and there are no solverOps, sponsor user gas
            // if (shMonad.balanceOfBonded(_policyId, _govPayoutAddr) > 0 && _solverCount() == 0) {
            //     uint256 _gasAmount = _gasLimit * tx.gasprice;
            //     shMonad.agentWithdrawFromBonded(_policyId, _govPayoutAddr, _user(), _gasAmount, 0, true);
            // }

            // If the input token is ETH, call the swap function with msg.value
            if (_swapInfo.inputToken == _ETH) {
                require(msg.value == _swapInfo.inputAmount, InsufficientUserOpValue());

                bool _routerWhitelist = BackrunDAppControl(payable(CONTROL)).isRouterWhitelisted(_swapInfo.target); 
                require(_routerWhitelist, UserOpDappNotSwapRouter());

                uint256 _outputTokenBalanceBefore = _balanceOf(_user(), _swapInfo.outputToken);

                (bool success, ) = _swapInfo.target.call{value: msg.value}(_swapInfo.swapData);
                require(success, SwapFailed());

                uint256 eeBalance = _balanceOf(address(this), _swapInfo.outputToken);
                if (eeBalance > 0) {
                    _transferToken(_swapInfo.outputToken, _user(), eeBalance);
                }

                uint256 _outputTokenBalanceAfter = _balanceOf(_user(), _swapInfo.outputToken);
                require(_outputTokenBalanceAfter - _outputTokenBalanceBefore >= _swapInfo.outputMin, InsufficientOutputBalance());
            }
        }
    }

    
    // ---------------------------------------------------- //
    //                     ATLAS HOOKS                      //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        (SwapTokenInfo memory _swapInfo, address _refundRecipient, uint256 _refundPercent, uint256 _gasLimit) 
            = abi.decode(userOp.data[4:], (SwapTokenInfo, address, uint256, uint256));
        require(_refundPercent <= BPS_SCALE - 1000, GovPercentExceedsScale());

        _setRefundParams(_refundRecipient, _refundPercent);
        _setGasLimit(_gasLimit);

        bool _routerWhitelist = BackrunDAppControl(payable(CONTROL)).isRouterWhitelisted(_swapInfo.target); 
        require(_routerWhitelist, UserOpDappNotSwapRouter());

        // If inputToken is ERC20, transfer tokens from user to EE, and approve router for swap
        if (userOp.value < _swapInfo.inputAmount) {
            if (_swapInfo.inputToken != _ETH) {
                _transferUserERC20(_swapInfo.inputToken, address(this), _swapInfo.inputAmount);
                SafeTransferLib.safeApprove(_swapInfo.inputToken, _swapInfo.target, _swapInfo.inputAmount);

                uint256 _outputTokenBalanceBefore = _balanceOf(userOp.from, _swapInfo.outputToken);

                (bool success, ) = _swapInfo.target.call(_swapInfo.swapData);
                require(success, SwapFailed());

                uint256 eeBalance = _balanceOf(address(this), _swapInfo.outputToken);
                if (eeBalance > 0) {
                    _transferToken(_swapInfo.outputToken, userOp.from, eeBalance);
                }

                uint256 _outputTokenBalanceAfter = _balanceOf(userOp.from, _swapInfo.outputToken);
                require(_outputTokenBalanceAfter - _outputTokenBalanceBefore >= _swapInfo.outputMin, InsufficientOutputBalance());
            } else {
                revert InsufficientUserOpValue();
            }    
        }        

        return userOp.data[4:]; 
    }

    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata data) internal virtual override {
        (SwapTokenInfo memory _swapInfo, , ) = abi.decode(data, (SwapTokenInfo, address, uint256));
        if (solverOp.bidToken != _swapInfo.outputToken) revert WrongBidToken();
    }

    function _allocateValueCall(bool solverSuccess, address _bidToken, uint256 bidAmount, bytes calldata) internal virtual override {
        (address _refundRecipient, uint256 _refundPercent) = _getRefundParams();
        (address _govPayoutAddr, uint256 _govPercent) = BackrunDAppControl(payable(CONTROL)).getPayoutData();
        require(_govPercent + _refundPercent <= BPS_SCALE, GovPercentExceedsScale());

        uint256 _outputTokenBalance = _balanceOf(address(this), _bidToken);
        require(_outputTokenBalance >= bidAmount, InsufficientOutputBalance());

        // Calculate governance, refund, and user amounts
        uint256 govPayoutAmount = (_outputTokenBalance * _govPercent) / BPS_SCALE;
        uint256 refundAmount = (_outputTokenBalance * _refundPercent) / BPS_SCALE;
        uint256 userAmount = _outputTokenBalance - govPayoutAmount - refundAmount;
        
        // Transfer governance amount to payout address if not zero
        if (govPayoutAmount > 0) {
            _transferToken(_bidToken, _govPayoutAddr, govPayoutAmount);
            emit GovernancePayout(_govPayoutAddr, govPayoutAmount);
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
        (SwapTokenInfo memory _swapInfo, , ) = abi.decode(userOp.data[4:], (SwapTokenInfo, address, uint256));
        return _swapInfo.bidTokenIsOutputToken ? _swapInfo.outputToken : _ETH;
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

    function getPolicyId() public view returns (uint64) {
        return policyId;
    }

    function isRouterWhitelisted(address _router) public view returns (bool) {
        return routerWhitelist[_router];
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

    function _setGasLimit(uint256 _gasLimit) internal {
        t_gasLimit = _gasLimit;
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
