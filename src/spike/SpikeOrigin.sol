// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title SpikeOrigin
/// @notice Step 1 spike only. Emits the origin event the spike reactive contract listens to.
///         The caller picks the callback gas limit so we can force InsufficientGas / CallbackFailure on purpose.
contract SpikeOrigin {
    event Ping(uint256 indexed id, uint256 gasLimit, uint256 work);

    uint256 public nextId = 1;

    /// @param gasLimit_ callback gas limit the reactive contract should request
    /// @param work_ number of storage slots the callback must write (controls how much gas it needs)
    function ping(uint256 gasLimit_, uint256 work_) external returns (uint256 id) {
        id = nextId++;
        emit Ping(id, gasLimit_, work_);
    }
}
