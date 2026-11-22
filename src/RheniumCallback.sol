// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IRheniumCallback} from "./IRhenium.sol";

/// @title RheniumCallback
/// @notice Inherit this instead of `AbstractCallback` on the destination chain.
///         Implement `_onDelivery`; Rhenium handles authentication, exactly-once execution and the
///         `Delivered` acknowledgement that tells the reactive contract the callback landed.
abstract contract RheniumCallback is AbstractCallback, IRheniumCallback {
    /// @notice receiptId => executed. A retry that races a late original delivery re-acknowledges
    ///         but never executes twice.
    mapping(uint256 => bool) public delivered;

    constructor(IPayable callbackProxy_, address callbackSender_) AbstractCallback(callbackProxy_, callbackSender_) {}

    /// @inheritdoc IRheniumCallback
    function rheniumDeliver(address rvm, uint256 receiptId, uint256 attempt, bytes calldata data)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        if (!delivered[receiptId]) {
            delivered[receiptId] = true;
            _onDelivery(receiptId, data);
        }
        // Emitted last: if `_onDelivery` reverts or runs out of gas there is no acknowledgement, and the
        // reactive side retries.
        emit Delivered(receiptId, attempt);
    }

    /// @inheritdoc IRheniumCallback
    function rheniumAlarm(address rvm, uint256 receiptId, uint256 chainId, address recipient, bytes calldata data)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        _onAlarm(receiptId, chainId, recipient, data);
        emit AlarmReceived(receiptId, chainId, recipient);
    }

    /// @notice Your destination logic. Revert to signal failure (Rhenium will retry with more gas).
    function _onDelivery(uint256 receiptId, bytes calldata data) internal virtual;

    /// @notice Called when a receipt this contract is the alarm target for ran out of attempts. Default: no-op.
    function _onAlarm(uint256 receiptId, uint256 chainId, address recipient, bytes calldata data) internal virtual {}

    /// @notice Settle outstanding debt with the callback proxy from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
