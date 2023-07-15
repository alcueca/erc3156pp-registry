// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.19;

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

interface IERC3156PPLender {

    /**
     * @dev Initiate a flash loan.
     * @param loanReceiver The receiver of the tokens in the loan
     * @param callbackReceiver The receiver of the callback.
     * @param asset The loan currency.
     * @param amount The amount of tokens lent.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @param callback The function to call on the callback receiver.
     * @return The returned data by the receiver of the flash loan.
     */
    function flashLoan(
        address loanReceiver,
        address callbackReceiver,
        ERC20 asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param callbackReceiver The contract receiving the callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, ERC20, uint256, uint256, bytes memory, address) external returns (bytes memory) callback
    ) external returns (bytes memory);

    /**
     * @dev The amount of currency available to be lended.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view returns (uint256);

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view returns (uint256);
}

interface Chooser {
    /// @dev Return the best of the lender for the given asset and amount.
    function choose(ERC3156PPLender[3], ERC20 asset, uint256 amount, bytes memory data) external returns (ERC3156PPLender);
}

contract Registry is Chooser {

    event FlashLoan(ERC20 indexed asset, uint256 amount, uint256 fee);
    event Set(address indexed user, ERC20 indexed asset, ERC3156PPLender[3] lenders, Chooser chooser);

    struct LenderSet {
        ERC3156PPLender[3] lenders;
        Chooser chooser;
        bool exists;
    }

    bool public inFlashLoan;

    mapping(address user => mapping(address asset => LenderSet)) public lenders;
    mapping(address asset => ERC3156PPLender) public lastLenders;

    /// @dev Set three lenders for the given asset, and an algorithm to choose between them.
    function set(ERC20 asset, ERC3156PPLender[3] lenders_, Chooser chooser_) external {
        lenders[msg.sender][asset] = LenderSet(lenders_, chooser_, true);

        emit Set(msg.sender, asset, lenders_, chooser_);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    function choose(ERC3156PPLender[3] lenders, ERC20 asset, uint256 amount, bytes memory) external view returns (ERC3156PPLender best) {
        return _choose(lenders, asset, amount, data);
    }

    /// @dev Return the lender that can service the loan for the lowest fee.
    function _choose(ERC3156PPLender[3] lenders, ERC20 asset, uint256 amount, bytes memory) internal view returns (ERC3156PPLender best) {
        uint256 cheapest = type(uint256).max;
        for (uint256 i = 0; i < 3; i++) {
            if (lenders[i] != ERC3156PPLender(address(0)) && lenders[i].maxFlashLoan(asset) >= amount) {
                uint256 cost = lenders[i].flashFee(asset, amount);
                if (cost < cheapest) {
                    cost = cheapest;
                    best = lenders[i];
                }
            }
        }
    }

    /// @dev Use the set lender to serve an ERC3156++ flash loan.
    function flashLoan(
        address loanReceiver,
        address callbackReceiver,
        ERC20 asset,
        uint256 amount,
        bytes calldata data,
        /// @dev callback
        /// @param callbackReceiver The contract receiving the callback
        /// @param loanReceiver The address receiving the flash loan
        /// @param asset The asset to be loaned
        /// @param amount The amount to loaned
        /// @param data The ABI encoded data to be passed to the callback
        /// @return result ABI encoded result of the callback
        function(address, ERC20, uint256, uint256, bytes memory, address) external returns (bytes memory) callback
    ) external returns (bytes memory) {
        require(!inFlashLoan, "No reentrancy");
        inFlashLoan = true;

        LenderSet storage lenderSet_ = lenders[msg.sender][asset];
        // If the user has registered a lender set for the asset, try to choose one.
        if (lenderSet_.exists) {
            lender = lenderSet_.chooser.choose(lenderSet_.lenders, asset, amount, data);
            if (lender != ERC3156PPLender(address(0))) lastLenders[asset] = lender;
        }
        // If not possible, use the last lender for that asset from other users.
        else lender = lastLenders[asset];
        
        require (lender != IERC3156PPLender(address(0)), "No lender found");

        bytes memory result = lender.flashLoan(
            loanReceiver,
            address(this),
            asset,
            amount,
            abi.encode(data, callbackReceiver, callback),
            this.forwardCallback(address, ERC20, uint256, uint256, bytes) // In many cases, for the callback receiver to trust the flash loan, the callback must come from a known contract. The aggregator contract can be used as a trusted forwarder.
        );
        inFlashLoan = false;
        return result;
    }

    /// @dev Forward the callback to the callback receiver, acting as a trusted forwarder.
    function forwardCallback(address loanReceiver, ERC20 asset, uint256 amount, uint256 fee, bytes memory outerData) external returns (bytes memory) {
        require(forwardCallbackLock, "Unauthorized callback");
        (
            bytes memory innerData,
            address callbackReceiver,
            function(address, ERC20, uint256, uint256, bytes memory) external returns (bytes memory) innerCallback
        ) = abi.decode(outerData, (
            bytes,
            address, 
            function(address, ERC20, uint256, uint256, bytes)
        ));

        emit FlashLoan(asset, amount, fee);
        return innerCallback(loanReceiver, asset, amount, fee, innerData);
    }
}
