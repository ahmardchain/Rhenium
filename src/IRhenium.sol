// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IRheniumCallback
/// @notice The fixed ABI between a RheniumReactive contract and its destination contracts.
/// @dev Keeping this ABI fixed is what lets the reactive side decode `receiptId` and `attempt` back out of the
///      callback proxy's `CallbackFailure(address,bytes payload)` event.
interface IRheniumCallback {
    /// @notice Emitted by the destination at the end of a successful delivery. This is the acknowledgement that
    ///         closes the loop: the reactive contract subscribes to it.
    event Delivered(uint256 indexed receiptId, uint256 attempt);

    /// @notice Emitted when an alarm (give-up notification) is received.
    event AlarmReceived(uint256 indexed receiptId, uint256 chainId, address recipient);

    /// @notice Delivery entry point. The proxy overwrites `rvm` with the requesting reactive contract.
    function rheniumDeliver(address rvm, uint256 receiptId, uint256 attempt, bytes calldata data) external;

    /// @notice Alarm entry point, called once when a receipt runs out of attempts.
    function rheniumAlarm(address rvm, uint256 receiptId, uint256 chainId, address recipient, bytes calldata data)
        external;
}

/// @title IRheniumReactive
/// @notice Events emitted on Reactive Network by a RheniumReactive contract. The dashboard reads these.
interface IRheniumReactive {
    enum Status {
        None,
        Pending,
        Confirmed,
        Failed
    }

    event ReceiptSent(
        uint256 indexed receiptId, uint256 indexed chainId, address indexed recipient, uint256 attempt, uint64 gasLimit
    );
    event ReceiptConfirmed(uint256 indexed receiptId, uint256 attempt, uint256 destTxHash);
    event ReceiptFailureSeen(uint256 indexed receiptId, uint256 attempt, uint256 destTxHash);
    event ReceiptTimedOut(uint256 indexed receiptId, uint256 attempt);
    event ReceiptGaveUp(uint256 indexed receiptId, uint256 attempts);
    event AlarmSent(uint256 indexed receiptId, uint256 chainId, address recipient);
    event CronSubscribed(uint256 topic);
    event CronUnsubscribed(uint256 topic);
}
