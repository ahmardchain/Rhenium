// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {RheniumCallback} from "../RheniumCallback.sol";
import {MockUSD} from "./MockUSD.sol";

/// @title RheniumPayee (destination chain, Unichain Sepolia)
/// @notice Holds mUSD liquidity and pays the recipient when a tracked callback lands. Exactly once per payment.
contract RheniumPayee is RheniumCallback {
    event Paid(uint256 indexed paymentId, address indexed to, uint256 amount, uint256 receiptId);

    MockUSD public immutable token;

    constructor(MockUSD token_, IPayable callbackProxy_, address reactive_)
        payable
        RheniumCallback(callbackProxy_, reactive_)
    {
        token = token_;
    }

    function _onDelivery(uint256 receiptId, bytes calldata data) internal override {
        (uint256 paymentId, address to, uint256 amount) = abi.decode(data, (uint256, address, uint256));
        token.transfer(to, amount);
        emit Paid(paymentId, to, amount, receiptId);
    }
}

/// @title NaivePayee (destination chain, Unichain Sepolia)
/// @notice The same payout written the usual way, on plain AbstractCallback. If the callback fails, nobody hears.
contract NaivePayee is AbstractCallback {
    event Paid(uint256 indexed paymentId, address indexed to, uint256 amount);

    MockUSD public immutable token;

    constructor(MockUSD token_, IPayable callbackProxy_, address reactive_)
        payable
        AbstractCallback(callbackProxy_, reactive_)
    {
        token = token_;
    }

    function release(address rvm, uint256 paymentId, address to, uint256 amount)
        external
        onlyServiceProvider
        onlyCallbackSender(rvm)
    {
        token.transfer(to, amount);
        emit Paid(paymentId, to, amount);
    }

    function coverDebt() external {
        _coverDebt();
    }
}
