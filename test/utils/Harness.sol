// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {RheniumReactive} from "../../src/RheniumReactive.sol";
import {RheniumCallback} from "../../src/RheniumCallback.sol";

/// @notice Minimal RheniumReactive exposing _sendTracked and counting hooks.
contract TestReactive is RheniumReactive {
    uint256 public confirmedHook;
    uint256 public gaveUpHook;
    uint256 public userLogs;

    constructor(Config memory c) RheniumReactive(c) {}

    function send(uint256 chainId_, address recipient_, uint64 gasLimit_, bytes calldata data_)
        external
        returns (uint256)
    {
        return _sendTracked(chainId_, recipient_, gasLimit_, data_);
    }

    function _react(LogRecord calldata) internal override {
        userLogs++;
    }

    function _onConfirmed(uint256) internal override {
        confirmedHook++;
    }

    function _onGaveUp(uint256) internal override {
        gaveUpHook++;
    }
}

/// @notice Destination: `data` = abi.encode(uint256 work); writes `work` storage slots so gas need is tunable.
contract TestDestination is RheniumCallback {
    uint256 public executions;
    uint256 public alarms;
    uint256 public lastAlarmId;
    mapping(uint256 => uint256) public slots;

    constructor(IPayable proxy_, address sender_) RheniumCallback(proxy_, sender_) {}

    function _onDelivery(uint256 receiptId, bytes calldata data) internal override {
        uint256 work = abi.decode(data, (uint256));
        for (uint256 i = 0; i < work; ++i) {
            slots[(receiptId << 32) | i] = i + 1;
        }
        executions++;
    }

    function _onAlarm(uint256 receiptId, uint256, address, bytes calldata) internal override {
        alarms++;
        lastAlarmId = receiptId;
    }
}
