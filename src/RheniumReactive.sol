// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {IRheniumCallback, IRheniumReactive} from "./IRhenium.sol";

/// @title RheniumReactive
/// @notice Inherit this instead of `AbstractReactive`. Call `_sendTracked(...)` instead of
///         `SYSTEM.requestCallbackV_1_0(...)`. Every callback gets a receipt that stays Pending until the
///         destination emits `Delivered`. Failures are detected two ways and retried with more gas:
///           1. the destination proxy's `CallbackFailure` event (callback method reverted / ran out of gas), and
///           2. a cron timeout (delivery reverted inside the proxy, e.g. InsufficientGas, which leaves no log).
///         After `maxAttempts` the receipt is marked Failed, `ReceiptGaveUp` is emitted and an optional alarm
///         callback is sent. Nothing disappears silently.
/// @dev Implement `_react(log)` for your own subscriptions; `react()` routes Rhenium's own events first.
abstract contract RheniumReactive is AbstractReactive, IRheniumReactive {
    // ------------------------------------------------------------------ constants
    uint256 internal constant DELIVERED_TOPIC = uint256(keccak256("Delivered(uint256,uint256)"));
    uint256 internal constant CALLBACK_FAILURE_TOPIC = uint256(keccak256("CallbackFailure(address,bytes)"));
    address internal constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON10_TOPIC = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 public constant CRON100_TOPIC = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 public constant CRON1000_TOPIC = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    /// @dev Minimum callback gas limit accepted by Reactive Network; lower requests are dropped.
    uint64 public constant MIN_CALLBACK_GAS = 100_000;
    /// @dev Receipts examined per cron tick, to bound the gas of a tick.
    uint256 public constant MAX_SCAN = 8;

    // ------------------------------------------------------------------ types
    struct Config {
        uint32 maxAttempts; // total sends allowed, including the first
        uint64 gasStep; // added to the gas limit on every retry
        uint64 maxGasLimit; // ceiling for the stepped gas limit
        uint32 cooldownBlocks; // min Reactive blocks between two sends of the same receipt
        uint32 timeoutBlocks; // Reactive blocks without Delivered before a send counts as lost
        uint256 cronTopic; // CRON10_TOPIC / CRON100_TOPIC / CRON1000_TOPIC
        bool cronEnabled; // false = rely on CallbackFailure only (no timeout detection)
        uint256 alarmChainId; // where to send the give-up alarm (0 = no alarm)
        address alarmRecipient;
        uint64 alarmGasLimit;
    }

    struct Receipt {
        uint256 chainId;
        address recipient;
        uint64 gasLimit; // gas limit of the latest send
        uint32 attempts; // number of sends so far
        Status status;
        bool retryDue; // a failure was seen inside the cooldown; next tick retries
        uint64 firstBlock;
        uint64 lastSentBlock;
        bytes data;
    }

    // ------------------------------------------------------------------ errors
    error NotOwner();
    error BadConfig();
    error UnknownProxy(uint256 chainId);

    // ------------------------------------------------------------------ storage
    address public owner;
    Config public config;
    uint256 public nextReceiptId = 1;
    mapping(uint256 => Receipt) internal _receipts;
    /// @notice destination chain id => callback proxy address on that chain
    mapping(uint256 => address) public callbackProxy;
    /// @notice keccak(chainId, recipient) => Delivered/CallbackFailure subscriptions exist
    mapping(bytes32 => bool) public watched;

    uint256[] internal _pending;
    mapping(uint256 => uint256) internal _pendingIndex; // receiptId => index + 1
    uint256 internal _cursor;
    bool public cronSubscribed;
    uint256 internal _cronTopicSubscribed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(Config memory config_) {
        owner = msg.sender;
        _setConfig(config_);
        // Testnet callback proxies (dev.reactive.network/origins-and-destinations).
        callbackProxy[84532] = 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
        callbackProxy[1301] = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1; // Unichain Sepolia
        callbackProxy[11155111] = 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4; // Ethereum Sepolia
    }

    // ================================================================== public API for inheritors

    /// @notice Request a tracked callback. Use instead of `SYSTEM.requestCallbackV_1_0`.
    /// @param chainId_ destination chain
    /// @param recipient_ destination contract (a RheniumCallback)
    /// @param gasLimit_ initial gas limit; raised by `gasStep` on each retry
    /// @param data_ opaque bytes handed to the destination's `_onDelivery(receiptId, data)`
    /// @return receiptId the receipt tracking this callback
    function _sendTracked(uint256 chainId_, address recipient_, uint64 gasLimit_, bytes memory data_)
        internal
        returns (uint256 receiptId)
    {
        _watch(chainId_, recipient_);
        receiptId = nextReceiptId++;
        Receipt storage r = _receipts[receiptId];
        r.chainId = chainId_;
        r.recipient = recipient_;
        r.gasLimit = gasLimit_ < MIN_CALLBACK_GAS ? MIN_CALLBACK_GAS : gasLimit_;
        r.status = Status.Pending;
        r.firstBlock = uint64(block.number);
        r.data = data_;
        _pending.push(receiptId);
        _pendingIndex[receiptId] = _pending.length;
        _send(receiptId);
        _syncCron();
    }

    /// @notice Your own event handling. Called for every log Rhenium does not consume.
    function _react(LogRecord calldata log_) internal virtual {}

    /// @notice Hook: a receipt was confirmed on the destination.
    function _onConfirmed(uint256 receiptId) internal virtual {}

    /// @notice Hook: a receipt ran out of attempts.
    function _onGaveUp(uint256 receiptId) internal virtual {}

    // ================================================================== views

    function getReceipt(uint256 receiptId_) external view returns (Receipt memory) {
        return _receipts[receiptId_];
    }

    function pendingCount() public view returns (uint256) {
        return _pending.length;
    }

    function pendingIds() external view returns (uint256[] memory) {
        return _pending;
    }

    // ================================================================== owner

    function setConfig(Config calldata config_) external onlyOwner {
        _setConfig(config_);
        _syncCron();
    }

    function setCallbackProxy(uint256 chainId_, address proxy_) external onlyOwner {
        callbackProxy[chainId_] = proxy_;
    }

    /// @notice Pre-subscribe to a destination's acknowledgements (also done lazily on first send).
    function watch(uint256 chainId_, address recipient_) external onlyOwner {
        _watch(chainId_, recipient_);
    }

    function transferOwnership(address owner_) external onlyOwner {
        owner = owner_;
    }

    /// @notice Settle debt with the system contract from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    // ================================================================== react

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == DELIVERED_TOPIC) {
            if (_onDeliveredLog(log_)) return;
        } else if (log_.topic0 == CALLBACK_FAILURE_TOPIC) {
            if (_onFailureLog(log_)) return;
        } else if (log_.contractAddress == CRON_SOURCE && log_.topic0 == _cronTopicSubscribed && cronSubscribed) {
            _onTick();
            return;
        }
        _react(log_);
    }

    // ================================================================== internals

    function _onDeliveredLog(LogRecord calldata log_) internal returns (bool) {
        uint256 id = log_.topic1;
        Receipt storage r = _receipts[id];
        if (r.status == Status.None || log_.contractAddress != r.recipient || log_.chainId != r.chainId) return false;
        if (r.status != Status.Pending) return true; // duplicate ack (exactly-once re-ack) or late ack
        uint256 attempt = abi.decode(log_.data, (uint256));
        r.status = Status.Confirmed;
        r.retryDue = false;
        _removePending(id);
        emit ReceiptConfirmed(id, attempt, log_.txHash);
        _onConfirmed(id);
        _syncCron();
        return true;
    }

    function _onFailureLog(LogRecord calldata log_) internal returns (bool) {
        if (log_.contractAddress != callbackProxy[log_.chainId] || log_.contractAddress == address(0)) return false;
        bytes memory payload = abi.decode(log_.data, (bytes));
        if (payload.length < 4 + 32 * 3) return false;
        bytes4 sel;
        uint256 id;
        uint256 attempt;
        assembly {
            sel := mload(add(payload, 32))
            id := mload(add(payload, 68)) // 32 len + 4 selector + 32 rvm
            attempt := mload(add(payload, 100))
        }
        if (sel != IRheniumCallback.rheniumDeliver.selector) return false;
        Receipt storage r = _receipts[id];
        if (r.status != Status.Pending || address(uint160(log_.topic1)) != r.recipient || log_.chainId != r.chainId) {
            return true;
        }
        if (attempt + 1 != r.attempts) return true; // stale: a newer attempt is already in flight
        emit ReceiptFailureSeen(id, attempt, log_.txHash);
        if (block.number >= r.lastSentBlock + config.cooldownBlocks) {
            _retry(id);
        } else {
            r.retryDue = true; // picked up by the next tick once the cooldown has passed
        }
        return true;
    }

    function _onTick() internal {
        uint256 n = _pending.length;
        if (n == 0) {
            _syncCron();
            return;
        }
        uint256 scan = n < MAX_SCAN ? n : MAX_SCAN;
        uint256 timeout = config.timeoutBlocks;
        uint256 cooldown = config.cooldownBlocks;
        for (uint256 k = 0; k < scan && _pending.length > 0; ++k) {
            if (_cursor >= _pending.length) _cursor = 0;
            uint256 id = _pending[_cursor];
            Receipt storage r = _receipts[id];
            bool due;
            if (r.retryDue && block.number >= r.lastSentBlock + cooldown) {
                due = true;
            } else if (block.number >= r.lastSentBlock + timeout) {
                emit ReceiptTimedOut(id, r.attempts - 1);
                due = true;
            }
            uint256 before = _pending.length;
            if (due) _retry(id);
            // If _retry gave up, the receipt was swap-removed: the same index now holds another id.
            if (_pending.length == before) _cursor++;
        }
        _syncCron();
    }

    function _retry(uint256 id_) internal {
        Receipt storage r = _receipts[id_];
        r.retryDue = false;
        if (r.attempts >= config.maxAttempts) {
            r.status = Status.Failed;
            _removePending(id_);
            emit ReceiptGaveUp(id_, r.attempts);
            _sendAlarm(id_);
            _onGaveUp(id_);
            return;
        }
        uint64 g = r.gasLimit + config.gasStep;
        r.gasLimit = g > config.maxGasLimit ? config.maxGasLimit : g;
        _send(id_);
    }

    function _send(uint256 id_) internal {
        Receipt storage r = _receipts[id_];
        uint256 attempt = r.attempts;
        r.attempts = uint32(attempt + 1);
        r.lastSentBlock = uint64(block.number);
        bytes memory payload =
            abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(0), id_, attempt, r.data);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: r.chainId, recipient: r.recipient, gasLimit: r.gasLimit, payload: payload
            })
        );
        emit ReceiptSent(id_, r.chainId, r.recipient, attempt, r.gasLimit);
    }

    function _sendAlarm(uint256 id_) internal {
        Config storage c = config;
        if (c.alarmRecipient == address(0)) return;
        Receipt storage r = _receipts[id_];
        bytes memory payload = abi.encodeWithSelector(
            IRheniumCallback.rheniumAlarm.selector, address(0), id_, r.chainId, r.recipient, r.data
        );
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: c.alarmChainId, recipient: c.alarmRecipient, gasLimit: c.alarmGasLimit, payload: payload
            })
        );
        emit AlarmSent(id_, c.alarmChainId, c.alarmRecipient);
    }

    function _watch(uint256 chainId_, address recipient_) internal {
        bytes32 key = keccak256(abi.encode(chainId_, recipient_));
        if (watched[key]) return;
        address proxy = callbackProxy[chainId_];
        if (proxy == address(0)) revert UnknownProxy(chainId_);
        watched[key] = true;
        SYSTEM.subscribe(chainId_, recipient_, DELIVERED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(
            chainId_, proxy, CALLBACK_FAILURE_TOPIC, uint256(uint160(recipient_)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @dev Keep cron subscribed only while receipts are pending (cron bills every tick).
    function _syncCron() internal {
        bool want = config.cronEnabled && _pending.length > 0;
        if (cronSubscribed && (!want || _cronTopicSubscribed != config.cronTopic)) {
            SYSTEM.unsubscribe(
                block.chainid, CRON_SOURCE, _cronTopicSubscribed, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            cronSubscribed = false;
            emit CronUnsubscribed(_cronTopicSubscribed);
        }
        if (want && !cronSubscribed) {
            _cronTopicSubscribed = config.cronTopic;
            SYSTEM.subscribe(
                block.chainid, CRON_SOURCE, _cronTopicSubscribed, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
            cronSubscribed = true;
            emit CronSubscribed(_cronTopicSubscribed);
        }
    }

    function _removePending(uint256 id_) internal {
        uint256 idx = _pendingIndex[id_];
        if (idx == 0) return;
        uint256 last = _pending[_pending.length - 1];
        _pending[idx - 1] = last;
        _pendingIndex[last] = idx;
        _pending.pop();
        delete _pendingIndex[id_];
    }

    function _setConfig(Config memory c) internal {
        if (
            c.maxAttempts == 0 || c.maxGasLimit < MIN_CALLBACK_GAS || c.timeoutBlocks == 0
                || (c.cronEnabled
                    && c.cronTopic != CRON10_TOPIC
                    && c.cronTopic != CRON100_TOPIC
                    && c.cronTopic != CRON1000_TOPIC)
                || (c.alarmRecipient != address(0) && c.alarmGasLimit < MIN_CALLBACK_GAS)
        ) revert BadConfig();
        config = c;
    }
}
