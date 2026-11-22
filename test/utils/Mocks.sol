// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Reactive system contract at 0x8888...8888. Records subscriptions and callback requests.
contract MockSystem {
    struct Req {
        address sender;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Req[] internal _reqs;
    mapping(bytes32 => uint256) public subs; // active subscription count per criteria set
    uint256 public subscribeCalls;
    uint256 public unsubscribeCalls;

    function _k(address who, uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(who, c, a, t0, t1, t2, t3));
    }

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscribeCalls++;
        subs[_k(msg.sender, c, a, t0, t1, t2, t3)] = 1; // duplicates behave as one (per docs)
    }

    function unsubscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        unsubscribeCalls++;
        subs[_k(msg.sender, c, a, t0, t1, t2, t3)] = 0;
    }

    function isSubscribed(address who, uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3)
        external
        view
        returns (bool)
    {
        return subs[_k(who, c, a, t0, t1, t2, t3)] != 0;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        _reqs.push(Req(msg.sender, c.chainId, c.recipient, c.gasLimit, c.payload));
    }

    function reqCount() external view returns (uint256) {
        return _reqs.length;
    }

    function req(uint256 i) external view returns (Req memory) {
        return _reqs[i];
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice Stand-in for a destination callback proxy, reproducing the two failure modes seen live:
///   * gasLimit below the proxy overhead -> the whole delivery tx reverts, no event (InsufficientGas)
///   * callback method reverts / runs out of gas -> CallbackFailure(recipient, payload), tx succeeds
contract MockProxy {
    event CallbackFailure(address indexed recipient, bytes payload);

    error InsufficientGas();

    uint256 public constant OVERHEAD = 50_000;

    function deliver(address rvm, address target, uint64 gasLimit, bytes memory payload) external {
        if (gasLimit < OVERHEAD) revert InsufficientGas();
        // Overwrite the first argument (bytes 4..36) with the requesting reactive contract.
        assembly {
            mstore(add(payload, 36), rvm)
        }
        (bool ok,) = target.call{gas: gasLimit - OVERHEAD}(payload);
        if (!ok) emit CallbackFailure(target, payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function depositTo(address) external payable {}

    receive() external payable {}
}
