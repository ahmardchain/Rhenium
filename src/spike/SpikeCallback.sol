// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title SpikeCallback
/// @notice Step 1 spike only. Destination contract: does a configurable amount of work, then emits Delivered.
contract SpikeCallback is AbstractCallback {
    event Delivered(uint256 indexed id, uint256 attempt, uint256 gasLeft);

    mapping(uint256 => uint256) public slots;
    mapping(uint256 => bool) public delivered;

    constructor(IPayable callbackProxy_, address callbackSender_) payable AbstractCallback(callbackProxy_, callbackSender_) { }

    /// @param rvm_ overwritten by the proxy with the requesting reactive contract
    function onPing(address rvm_, uint256 id_, uint256 attempt_, uint256 work_)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm_)
    {
        // Burn gas deterministically: write `work_` fresh storage slots (~22k gas each).
        for (uint256 i = 0; i < work_; ++i) {
            slots[(id_ << 32) | (attempt_ << 16) | i] = block.number;
        }
        delivered[id_] = true;
        emit Delivered(id_, attempt_, gasleft());
    }

    function coverDebt() external {
        _coverDebt();
    }
}
