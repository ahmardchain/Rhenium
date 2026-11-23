// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {RheniumCallback} from "../RheniumCallback.sol";
import {MockUSD} from "./MockUSD.sol";

/// @title Payer (origin chain, Base Sepolia)
/// @notice A payer escrows mUSD here and asks for it to be paid out to `to` on the destination chain.
///         The payment is triggered purely by the `PaymentRequested` event: no bridge, no bot.
///         The same contract is used for both the naive and the Rhenium flow; only the Rhenium flow can ever
///         call back here (the alarm), to refund a payment that ran out of attempts.
contract Payer is RheniumCallback {
    enum State {
        None,
        Requested,
        Refunded
    }

    struct Payment {
        address payer;
        address to;
        uint256 amount;
        State state;
    }

    event PaymentRequested(uint256 indexed id, address indexed to, uint256 amount, uint64 gasLimit, address payer);
    event PaymentRefunded(uint256 indexed id, address indexed payer, uint256 amount, uint256 receiptId);

    MockUSD public immutable token;
    uint256 public nextId = 1;
    mapping(uint256 => Payment) public payments;

    constructor(MockUSD token_, IPayable callbackProxy_, address reactive_)
        payable
        RheniumCallback(callbackProxy_, reactive_)
    {
        token = token_;
    }

    /// @param gasLimit_ callback gas limit the reactive side should start with (the demo sets it too low on purpose)
    function pay(address to_, uint256 amount_, uint64 gasLimit_) external returns (uint256 id) {
        token.transferFrom(msg.sender, address(this), amount_);
        id = nextId++;
        payments[id] = Payment(msg.sender, to_, amount_, State.Requested);
        emit PaymentRequested(id, to_, amount_, gasLimit_, msg.sender);
    }

    /// @dev Delivery is not used on the origin chain.
    function _onDelivery(uint256, bytes calldata) internal pure override {
        revert("Payer: not a destination");
    }

    /// @notice Rhenium gave up on the payout: refund the escrow. Never silent.
    function _onAlarm(uint256 receiptId, uint256, address, bytes calldata data) internal override {
        (uint256 id,,) = abi.decode(data, (uint256, address, uint256));
        Payment storage p = payments[id];
        if (p.state != State.Requested) return;
        p.state = State.Refunded;
        token.transfer(p.payer, p.amount);
        emit PaymentRefunded(id, p.payer, p.amount, receiptId);
    }
}
