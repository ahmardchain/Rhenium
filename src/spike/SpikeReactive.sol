// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title SpikeReactive
/// @notice Step 1 spike only (S1-S4). Lives on Reactive Lasna.
///   S1: Ping on origin -> callback -> Delivered on destination -> seen here.
///   S2: CallbackFailure on the destination proxy (topic1 = our callback contract) -> seen here.
///   S3: on CallbackFailure, re-request the same callback with a higher gas limit.
///   S4: Cron10 is subscribed only while something is pending; ticks drive a timeout check.
contract SpikeReactive is AbstractReactive {
    // keccak256("Ping(uint256,uint256,uint256)")
    uint256 internal constant PING_TOPIC = uint256(keccak256("Ping(uint256,uint256,uint256)"));
    uint256 internal constant DELIVERED_TOPIC = uint256(keccak256("Delivered(uint256,uint256,uint256)"));
    uint256 internal constant CALLBACK_FAILURE_TOPIC = uint256(keccak256("CallbackFailure(address,bytes)"));
    address internal constant LEGACY_SYSTEM = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON10_TOPIC = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    uint256 public constant MAX_ATTEMPTS = 4;
    uint64 public constant GAS_STEP = 200_000;
    uint256 public constant TIMEOUT_BLOCKS = 120; // ~2 min on Lasna

    event Requested(uint256 indexed id, uint256 attempt, uint64 gasLimit);
    event Confirmed(uint256 indexed id, uint256 attempt, uint256 destTxHash);
    event FailureSeen(uint256 indexed id, uint256 attempt, uint256 destTxHash);
    event TimedOut(uint256 indexed id, uint256 attempt);
    event GaveUp(uint256 indexed id, uint256 attempts);
    event Tick(uint256 blockNumber, uint256 pending);
    event Cron(bool on);

    struct P {
        uint64 gasLimit;
        uint32 attempt;
        uint32 work;
        uint8 status; // 0 none, 1 pending, 2 confirmed, 3 failed
        uint64 sentBlock;
    }

    address public owner;
    uint256 public immutable originChainId;
    address public immutable origin;
    uint256 public immutable destChainId;
    address public immutable destProxy;
    address public callback;
    bool public cronOn;
    uint256 public pending;
    uint256 public ticks;
    mapping(uint256 => P) public ps;
    uint256[] public ids;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(uint256 originChainId_, address origin_, uint256 destChainId_, address destProxy_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        origin = origin_;
        destChainId = destChainId_;
        destProxy = destProxy_;
        SYSTEM.subscribe(originChainId_, origin_, PING_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @notice Deployment-order break: set the destination callback contract after it is deployed with our address.
    function setCallback(address cb_) external onlyOwner {
        require(callback == address(0), "set");
        callback = cb_;
        SYSTEM.subscribe(destChainId, cb_, DELIVERED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(destChainId, destProxy, CALLBACK_FAILURE_TOPIC, uint256(uint160(cb_)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function setCron(bool on_) external onlyOwner {
        _setCron(on_);
    }

    function coverDebt() external {
        _coverDebt();
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == PING_TOPIC && log_.contractAddress == origin && log_.chainId == originChainId) {
            (uint256 gasLimit, uint256 work) = abi.decode(log_.data, (uint256, uint256));
            uint256 id = log_.topic1;
            ps[id] = P(uint64(gasLimit), 0, uint32(work), 1, uint64(block.number));
            ids.push(id);
            pending++;
            _send(id);
            if (!cronOn) _setCron(true);
        } else if (log_.topic0 == DELIVERED_TOPIC && log_.contractAddress == callback && log_.chainId == destChainId) {
            uint256 id = log_.topic1;
            P storage p = ps[id];
            if (p.status == 1) {
                p.status = 2;
                pending--;
                emit Confirmed(id, p.attempt, log_.txHash);
            }
        } else if (log_.topic0 == CALLBACK_FAILURE_TOPIC && log_.contractAddress == destProxy && log_.chainId == destChainId) {
            bytes memory payload = abi.decode(log_.data, (bytes));
            if (payload.length < 4 + 32 * 4) return;
            uint256 id;
            uint256 attempt;
            assembly {
                id := mload(add(payload, 68)) // 32 (len) + 4 (selector) + 32 (rvm)
                attempt := mload(add(payload, 100))
            }
            P storage p = ps[id];
            if (p.status != 1 || attempt != p.attempt) return; // stale or unknown
            emit FailureSeen(id, attempt, log_.txHash);
            _retry(id);
        } else if (log_.topic0 == CRON10_TOPIC && log_.contractAddress == LEGACY_SYSTEM) {
            ticks++;
            emit Tick(block.number, pending);
            if (pending == 0) {
                _setCron(false);
                return;
            }
            uint256 n = ids.length;
            uint256 from = n > 16 ? n - 16 : 0; // bounded scan
            for (uint256 i = from; i < n; ++i) {
                P storage p = ps[ids[i]];
                if (p.status == 1 && block.number > p.sentBlock + TIMEOUT_BLOCKS) {
                    emit TimedOut(ids[i], p.attempt);
                    _retry(ids[i]);
                }
            }
        }
    }

    function _retry(uint256 id_) internal {
        P storage p = ps[id_];
        if (p.attempt + 1 >= MAX_ATTEMPTS) {
            p.status = 3;
            pending--;
            emit GaveUp(id_, p.attempt + 1);
            return;
        }
        p.attempt++;
        p.gasLimit += GAS_STEP;
        p.sentBlock = uint64(block.number);
        _send(id_);
    }

    function _send(uint256 id_) internal {
        P storage p = ps[id_];
        bytes memory payload = abi.encodeWithSignature(
            "onPing(address,uint256,uint256,uint256)", address(0), id_, uint256(p.attempt), uint256(p.work)
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId, recipient: callback, gasLimit: p.gasLimit, payload: payload
            })
        );
        emit Requested(id_, p.attempt, p.gasLimit);
    }

    function _setCron(bool on_) internal {
        if (on_ == cronOn) return;
        cronOn = on_;
        if (on_) {
            SYSTEM.subscribe(block.chainid, LEGACY_SYSTEM, CRON10_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, LEGACY_SYSTEM, CRON10_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit Cron(on_);
    }
}
