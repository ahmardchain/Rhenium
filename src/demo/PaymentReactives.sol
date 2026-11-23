// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {RheniumReactive} from "../RheniumReactive.sol";

uint256 constant PAYMENT_REQUESTED_TOPIC =
    uint256(keccak256("PaymentRequested(uint256,address,uint256,uint64,address)"));

/// @title NaivePaymentReactive (Reactive Lasna)
/// @notice The usual pattern: watch PaymentRequested, fire requestCallbackV_1_0, hope it lands.
contract NaivePaymentReactive is AbstractReactive {
    event PayoutRequested(uint256 indexed paymentId, address to, uint256 amount, uint64 gasLimit);

    address public immutable owner;
    uint256 public immutable originChainId;
    uint256 public immutable destChainId;
    address public payer; // origin contract
    address public payee; // destination contract

    constructor(uint256 originChainId_, uint256 destChainId_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        destChainId = destChainId_;
    }

    /// @notice Deployment-order break: link the origin Payer and the destination Payee once both exist.
    function link(address payer_, address payee_) external {
        require(msg.sender == owner && payer == address(0), "link");
        payer = payer_;
        payee = payee_;
        SYSTEM.subscribe(
            originChainId, payer_, PAYMENT_REQUESTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != PAYMENT_REQUESTED_TOPIC || log_.contractAddress != payer || log_.chainId != originChainId) {
            return;
        }
        (uint256 amount, uint64 gasLimit,) = abi.decode(log_.data, (uint256, uint64, address));
        address to = address(uint160(log_.topic2));
        bytes memory payload =
            abi.encodeWithSignature("release(address,uint256,address,uint256)", address(0), log_.topic1, to, amount);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: payee, gasLimit: gasLimit, payload: payload
            })
        );
        emit PayoutRequested(log_.topic1, to, amount, gasLimit);
    }

    function coverDebt() external {
        _coverDebt();
    }
}

/// @title RheniumPaymentReactive (Reactive Lasna)
/// @notice The same payout, tracked: `_sendTracked` instead of `requestCallbackV_1_0`. Lost or failed payouts are
///         retried with more gas until the payee acknowledges; if all attempts fail, the Payer refunds.
contract RheniumPaymentReactive is RheniumReactive {
    event PayoutTracked(uint256 indexed paymentId, uint256 indexed receiptId, address to, uint256 amount);

    uint256 public immutable originChainId;
    uint256 public immutable destChainId;
    address public payer;
    address public payee;
    mapping(uint256 => uint256) public paymentOfReceipt;
    mapping(uint256 => uint256) public receiptOfPayment;

    constructor(uint256 originChainId_, uint256 destChainId_, Config memory config_) payable RheniumReactive(config_) {
        originChainId = originChainId_;
        destChainId = destChainId_;
    }

    /// @notice Link Payer (origin + alarm target) and Payee (destination) after both are deployed.
    function link(address payer_, address payee_, uint64 alarmGasLimit_) external onlyOwner {
        require(payer == address(0), "linked");
        payer = payer_;
        payee = payee_;
        Config memory c = config;
        c.alarmChainId = originChainId;
        c.alarmRecipient = payer_;
        c.alarmGasLimit = alarmGasLimit_;
        _setConfig(c);
        _watch(destChainId, payee_);
        SYSTEM.subscribe(
            originChainId, payer_, PAYMENT_REQUESTED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    function _react(LogRecord calldata log_) internal override {
        if (log_.topic0 != PAYMENT_REQUESTED_TOPIC || log_.contractAddress != payer || log_.chainId != originChainId) {
            return;
        }
        (uint256 amount, uint64 gasLimit,) = abi.decode(log_.data, (uint256, uint64, address));
        uint256 paymentId = log_.topic1;
        if (receiptOfPayment[paymentId] != 0) return; // duplicate origin log
        address to = address(uint160(log_.topic2));
        uint256 rid = _sendTracked(destChainId, payee, gasLimit, abi.encode(paymentId, to, amount));
        paymentOfReceipt[rid] = paymentId;
        receiptOfPayment[paymentId] = rid;
        emit PayoutTracked(paymentId, rid, to, amount);
    }
}
