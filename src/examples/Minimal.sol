// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {RheniumReactive} from "../RheniumReactive.sol";
import {RheniumCallback} from "../RheniumCallback.sol";

/// @notice The README's "10 lines" example, compiled as part of the build so it cannot drift.
contract MyReactive is RheniumReactive {
    address public myCallback; // set after deploying MyCallback (deployment order)

    constructor(Config memory c) payable RheniumReactive(c) {}

    function setCallback(address cb) external onlyOwner {
        myCallback = cb;
    }

    function _react(LogRecord calldata log_) internal override {
        _sendTracked(1301, myCallback, 200_000, abi.encode(log_.topic1)); // instead of requestCallbackV_1_0
    }
}

contract MyCallback is RheniumCallback {
    event Acted(uint256 receiptId, uint256 value);

    constructor(IPayable proxy, address reactive) payable RheniumCallback(proxy, reactive) {}

    function _onDelivery(uint256 receiptId, bytes calldata data) internal override {
        emit Acted(receiptId, abi.decode(data, (uint256)));
    }
}
