// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {RheniumReactive} from "../src/RheniumReactive.sol";
import {IRheniumReactive, IRheniumCallback} from "../src/IRhenium.sol";
import {MockSystem, MockProxy} from "./utils/Mocks.sol";
import {TestReactive, TestDestination} from "./utils/Harness.sol";

contract RheniumTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia proxy address
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant DEST = 84532;
    uint256 constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 constant DELIVERED_TOPIC = uint256(keccak256("Delivered(uint256,uint256)"));
    uint256 constant FAILURE_TOPIC = uint256(keccak256("CallbackFailure(address,bytes)"));

    MockSystem sys;
    MockProxy proxy;
    TestReactive r;
    TestDestination dst;
    TestDestination alarm;
    uint256 delivered; // number of system requests already pumped
    uint256 gaveUpId; // last ReceiptGaveUp seen by _pump
    uint256 gaveUpAttempts;

    // work units: each writes one fresh slot (~22.1k gas). Gas need for `work` = ~22.5k*work + ~10k.
    uint256 constant WORK = 5; // ~120k forwarded: fails at 150k gasLimit (100k forwarded), fits at 300k

    function _cfg() internal pure returns (RheniumReactive.Config memory c) {
        c.maxAttempts = 4;
        c.gasStep = 150_000;
        c.maxGasLimit = 1_000_000;
        c.cooldownBlocks = 0;
        c.timeoutBlocks = 30;
        c.cronTopic = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70; // Cron100
        c.cronEnabled = true;
    }

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        vm.etch(PROXY, address(new MockProxy()).code);
        sys = MockSystem(payable(SYS));
        proxy = MockProxy(payable(PROXY));
        r = new TestReactive(_cfg());
        // Deployment order: reactive first, then the destination with the reactive's address.
        dst = new TestDestination(IPayable(payable(PROXY)), address(r));
        alarm = new TestDestination(IPayable(payable(PROXY)), address(r));
    }

    // ------------------------------------------------------------------ helpers

    function _log(uint256 chainId, address c, uint256 t0, uint256 t1, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = chainId;
        l.contractAddress = c;
        l.topic0 = t0;
        l.topic1 = t1;
        l.data = data;
        l.txHash = 0xbeef;
    }

    /// Deliver every new system request through the mock proxy and feed resulting logs back into react().
    /// Returns the number of logs fed back.
    function _pump() internal returns (uint256 fed) {
        for (; delivered < sys.reqCount(); ++delivered) {
            MockSystem.Req memory q = sys.req(delivered);
            vm.recordLogs();
            try proxy.deliver(q.sender, q.recipient, q.gasLimit, q.payload) {} catch {}
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; ++i) {
                Vm.Log memory lg = logs[i];
                uint256 t0 = uint256(lg.topics[0]);
                if (t0 != DELIVERED_TOPIC && t0 != FAILURE_TOPIC) continue;
                vm.recordLogs();
                vm.prank(SYS);
                r.react(_log(DEST, lg.emitter, t0, uint256(lg.topics[1]), lg.data));
                fed++;
                Vm.Log[] memory out = vm.getRecordedLogs();
                for (uint256 j = 0; j < out.length; ++j) {
                    if (out[j].emitter == address(r) && out[j].topics[0] == IRheniumReactive.ReceiptGaveUp.selector) {
                        gaveUpId = uint256(out[j].topics[1]);
                        gaveUpAttempts = abi.decode(out[j].data, (uint256));
                    }
                }
            }
        }
    }

    function _tick() internal {
        vm.prank(SYS);
        r.react(_log(5318007, CRON, _cfg().cronTopic, 0, abi.encode(block.number)));
    }

    function _send(uint64 gas, uint256 work) internal returns (uint256) {
        return r.send(DEST, address(dst), gas, abi.encode(work));
    }

    function _status(uint256 id) internal view returns (IRheniumReactive.Status) {
        return r.getReceipt(id).status;
    }

    // ------------------------------------------------------------------ lifecycle

    function test_PendingToConfirmed() public {
        uint256 id = _send(1_000_000, WORK);
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Pending));
        assertEq(r.pendingCount(), 1);
        _pump();
        RheniumReactive.Receipt memory rc = r.getReceipt(id);
        assertEq(uint8(rc.status), uint8(IRheniumReactive.Status.Confirmed));
        assertEq(rc.attempts, 1);
        assertEq(r.pendingCount(), 0);
        assertEq(dst.executions(), 1);
        assertEq(r.confirmedHook(), 1);
    }

    function test_FailureEvent_RetryWithMoreGas_ThenConfirmed() public {
        // 150k clears the proxy overhead but not the method: CallbackFailure, then retry at 300k succeeds.
        uint256 id = _send(150_000, WORK);
        vm.expectEmit(true, false, false, false, address(r));
        emit IRheniumReactive.ReceiptFailureSeen(id, 0, 0);
        _pump();
        RheniumReactive.Receipt memory rc = r.getReceipt(id);
        assertEq(uint8(rc.status), uint8(IRheniumReactive.Status.Confirmed));
        assertEq(rc.attempts, 2);
        assertEq(rc.gasLimit, 300_000);
        assertEq(dst.executions(), 1);
    }

    function test_SilentRevert_TimeoutRetry_ThenConfirmed() public {
        // Below the proxy overhead: the delivery reverts and leaves no log. Only the timeout catches it.
        uint256 id = r.send(DEST, address(dst), 100_000, abi.encode(uint256(0)));
        vm.etch(PROXY, address(new StrictProxy()).code); // overhead 120k > 100k: InsufficientGas, no event
        assertEq(_pump(), 0);
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Pending));

        vm.roll(block.number + 29);
        _tick();
        assertEq(r.getReceipt(id).attempts, 1, "no retry before timeout");

        vm.roll(block.number + 1);
        vm.expectEmit(true, false, false, true, address(r));
        emit IRheniumReactive.ReceiptTimedOut(id, 0);
        _tick();
        assertEq(r.getReceipt(id).attempts, 2);
        assertEq(r.getReceipt(id).gasLimit, 250_000);
        _pump();
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Confirmed));
    }

    function test_MaxAttempts_Failed_GaveUp_Alarm() public {
        RheniumReactive.Config memory c = _cfg();
        c.alarmChainId = DEST;
        c.alarmRecipient = address(alarm);
        c.alarmGasLimit = 200_000;
        r.setConfig(c);

        // 200 slots never fits under maxGasLimit=1M: every attempt fails.
        uint256 id = _send(150_000, 200);
        _pump();
        assertEq(gaveUpId, id, "ReceiptGaveUp emitted for this receipt");
        assertEq(gaveUpAttempts, 4);
        RheniumReactive.Receipt memory rc = r.getReceipt(id);
        assertEq(uint8(rc.status), uint8(IRheniumReactive.Status.Failed));
        assertEq(rc.attempts, 4);
        assertEq(r.pendingCount(), 0);
        assertEq(r.gaveUpHook(), 1);
        assertEq(dst.executions(), 0);
        // the alarm callback was requested and delivered to the alarm target
        assertEq(alarm.alarms(), 1);
        assertEq(alarm.lastAlarmId(), id);
        MockSystem.Req memory last = sys.req(sys.reqCount() - 1);
        assertEq(bytes4(last.payload), IRheniumCallback.rheniumAlarm.selector);
        assertEq(last.recipient, address(alarm));
    }

    function test_NoAlarmWhenUnset() public {
        _send(150_000, 200);
        uint256 before = sys.reqCount();
        _pump();
        // 1 initial + 3 retries, no alarm
        assertEq(sys.reqCount(), before + 3);
    }

    // ------------------------------------------------------------------ gas step and ceiling

    function test_GasStep_IncreasesEachRetry_CappedAtMax() public {
        RheniumReactive.Config memory c = _cfg();
        c.maxAttempts = 10;
        c.gasStep = 300_000;
        c.maxGasLimit = 700_000;
        r.setConfig(c);
        _send(150_000, 1000); // never succeeds
        _pump();
        uint64[10] memory want =
            [uint64(150_000), 450_000, 700_000, 700_000, 700_000, 700_000, 700_000, 700_000, 700_000, 700_000];
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(sys.req(i).gasLimit, want[i]);
        }
    }

    function test_MinimumGasLimitEnforced() public {
        uint256 id = _send(10_000, 0);
        assertEq(r.getReceipt(id).gasLimit, 100_000);
    }

    function testFuzz_GasSchedule(uint64 g0, uint64 step, uint8 fails) public {
        g0 = uint64(bound(g0, 100_000, 2_000_000));
        step = uint64(bound(step, 0, 500_000));
        fails = uint8(bound(fails, 0, 6));
        RheniumReactive.Config memory c = _cfg();
        c.maxAttempts = 8;
        c.gasStep = step;
        c.maxGasLimit = 3_000_000;
        r.setConfig(c);
        uint256 id = r.send(DEST, address(dst), g0, "");
        for (uint256 i = 0; i < fails; ++i) {
            bytes memory p =
                abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(r), id, i, bytes(""));
            vm.prank(SYS);
            r.react(_log(DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(dst))), abi.encode(p)));
        }
        uint256 expect = uint256(g0) + uint256(step) * fails;
        if (expect > 3_000_000) expect = 3_000_000;
        assertEq(r.getReceipt(id).gasLimit, expect);
        assertEq(r.getReceipt(id).attempts, fails + 1);
    }

    // ------------------------------------------------------------------ cooldown

    function test_Cooldown_DefersRetryToTick() public {
        RheniumReactive.Config memory c = _cfg();
        c.cooldownBlocks = 5;
        r.setConfig(c);
        uint256 id = _send(150_000, WORK);
        _pump(); // CallbackFailure arrives in the same block: inside cooldown
        RheniumReactive.Receipt memory rc = r.getReceipt(id);
        assertEq(rc.attempts, 1, "no immediate retry inside cooldown");
        assertTrue(rc.retryDue);

        vm.roll(block.number + 4);
        _tick();
        assertEq(r.getReceipt(id).attempts, 1, "still cooling down");

        vm.roll(block.number + 1);
        _tick();
        assertEq(r.getReceipt(id).attempts, 2, "retried once cooldown passed");
        assertFalse(r.getReceipt(id).retryDue);
        _pump();
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Confirmed));
    }

    // ------------------------------------------------------------------ cron lifecycle

    function _cronSubbed(uint256 topic) internal view returns (bool) {
        return
            sys.isSubscribed(address(r), block.chainid, CRON, topic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function test_Cron_SubscribesWhilePending_UnsubscribesWhenEmpty_Resubscribes() public {
        uint256 t = _cfg().cronTopic;
        assertFalse(_cronSubbed(t), "idle: no cron");
        uint256 a = _send(1_000_000, 1);
        assertTrue(_cronSubbed(t), "pending: cron on");
        uint256 b = _send(1_000_000, 1);
        assertTrue(r.cronSubscribed());
        // confirm a only
        delivered = 0;
        MockSystem.Req memory q = sys.req(0);
        vm.recordLogs();
        proxy.deliver(q.sender, q.recipient, q.gasLimit, q.payload);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.prank(SYS);
        r.react(
            _log(
                DEST,
                address(dst),
                DELIVERED_TOPIC,
                uint256(logs[logs.length - 1].topics[1]),
                logs[logs.length - 1].data
            )
        );
        delivered = 1;
        assertEq(uint8(_status(a)), uint8(IRheniumReactive.Status.Confirmed));
        assertTrue(_cronSubbed(t), "one still pending");
        _pump();
        assertEq(uint8(_status(b)), uint8(IRheniumReactive.Status.Confirmed));
        assertFalse(_cronSubbed(t), "empty: cron off");
        assertFalse(r.cronSubscribed());
        _send(1_000_000, 1);
        assertTrue(_cronSubbed(t), "refilled: cron on again");
    }

    function test_Cron_Disabled_NeverSubscribes() public {
        RheniumReactive.Config memory c = _cfg();
        c.cronEnabled = false;
        r.setConfig(c);
        _send(1_000_000, 1);
        assertFalse(r.cronSubscribed());
        assertFalse(_cronSubbed(c.cronTopic));
    }

    function test_Cron_SwitchTopicWhilePending() public {
        _send(1_000_000, 1);
        RheniumReactive.Config memory c = _cfg();
        c.cronTopic = r.CRON10_TOPIC();
        r.setConfig(c);
        assertFalse(_cronSubbed(_cfg().cronTopic), "old topic dropped");
        assertTrue(_cronSubbed(c.cronTopic), "new topic subscribed");
    }

    function test_Cron_OwnerCanSwitchOff() public {
        _send(1_000_000, 1);
        RheniumReactive.Config memory c = _cfg();
        c.cronEnabled = false;
        r.setConfig(c);
        assertFalse(r.cronSubscribed());
    }

    function test_Tick_IgnoredWhenNotSubscribed() public {
        // A stray cron log when we're not subscribed goes to the user hook, not the timeout logic.
        _tick();
        assertEq(r.userLogs(), 1);
    }

    // ------------------------------------------------------------------ matching and filtering

    function test_StaleFailureIgnored() public {
        uint256 id = _send(150_000, WORK);
        bytes memory p0 =
            abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(r), id, 0, abi.encode(WORK));
        vm.startPrank(SYS);
        r.react(_log(DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(dst))), abi.encode(p0)));
        assertEq(r.getReceipt(id).attempts, 2);
        r.react(_log(DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(dst))), abi.encode(p0))); // attempt 0 again
        vm.stopPrank();
        assertEq(r.getReceipt(id).attempts, 2, "stale failure must not trigger another retry");
    }

    function test_FailureForOtherRecipientIgnored() public {
        uint256 id = _send(150_000, WORK);
        bytes memory p = abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(r), id, 0, "");
        vm.prank(SYS);
        r.react(_log(DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(0xBAD))), abi.encode(p)));
        assertEq(r.getReceipt(id).attempts, 1);
    }

    function test_FailureFromWrongProxyFallsThrough() public {
        uint256 id = _send(150_000, WORK);
        bytes memory p = abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(r), id, 0, "");
        vm.prank(SYS);
        r.react(_log(DEST, address(0xF00D), FAILURE_TOPIC, uint256(uint160(address(dst))), abi.encode(p)));
        assertEq(r.getReceipt(id).attempts, 1);
        assertEq(r.userLogs(), 1);
    }

    function test_ForeignFailurePayloadFallsThroughToUser() public {
        bytes memory p = abi.encodeWithSignature("other(address,uint256,uint256,uint256)", address(r), 1, 0, 0);
        vm.prank(SYS);
        r.react(_log(DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(dst))), abi.encode(p)));
        assertEq(r.userLogs(), 1);
    }

    function test_DeliveredFromWrongContractIgnored() public {
        uint256 id = _send(1_000_000, WORK);
        vm.prank(SYS);
        r.react(_log(DEST, address(0xBAD), DELIVERED_TOPIC, id, abi.encode(uint256(0))));
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Pending));
        vm.prank(SYS);
        r.react(_log(1301, address(dst), DELIVERED_TOPIC, id, abi.encode(uint256(0)))); // wrong chain
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Pending));
    }

    function test_LateAckAfterGiveUpIsNoOp() public {
        uint256 id = _send(150_000, 200);
        _pump();
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Failed));
        vm.prank(SYS);
        r.react(_log(DEST, address(dst), DELIVERED_TOPIC, id, abi.encode(uint256(0))));
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Failed));
        assertEq(r.userLogs(), 0);
    }

    // ------------------------------------------------------------------ deployment-order linkage

    function test_FirstSendSubscribesToRecipientAcks() public {
        assertFalse(
            sys.isSubscribed(
                address(r), DEST, address(dst), DELIVERED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            )
        );
        _send(1_000_000, 1);
        assertTrue(
            sys.isSubscribed(
                address(r), DEST, address(dst), DELIVERED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            )
        );
        assertTrue(
            sys.isSubscribed(
                address(r), DEST, PROXY, FAILURE_TOPIC, uint256(uint160(address(dst))), REACTIVE_IGNORE, REACTIVE_IGNORE
            )
        );
        uint256 calls = sys.subscribeCalls();
        _send(1_000_000, 1);
        assertEq(sys.subscribeCalls(), calls, "second send does not resubscribe");
    }

    function test_OwnerCanPreWatch() public {
        r.watch(DEST, address(dst));
        assertTrue(r.watched(keccak256(abi.encode(DEST, address(dst)))));
    }

    function test_UnknownDestinationChainReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RheniumReactive.UnknownProxy.selector, 999));
        r.send(999, address(dst), 200_000, "");
    }

    function test_DestinationAuthorizesOnlyItsReactive() public view {
        assertEq(dst._CALLBACK_SENDER(), address(r));
    }

    function test_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(RheniumReactive.NotOwner.selector);
        r.setConfig(_cfg());
        vm.prank(address(0xBEEF));
        vm.expectRevert(RheniumReactive.NotOwner.selector);
        r.watch(DEST, address(dst));
    }

    function test_BadConfigRejected() public {
        RheniumReactive.Config memory c = _cfg();
        c.maxAttempts = 0;
        vm.expectRevert(RheniumReactive.BadConfig.selector);
        r.setConfig(c);
        c = _cfg();
        c.cronTopic = 123;
        vm.expectRevert(RheniumReactive.BadConfig.selector);
        r.setConfig(c);
        c = _cfg();
        c.alarmRecipient = address(alarm);
        c.alarmGasLimit = 1;
        vm.expectRevert(RheniumReactive.BadConfig.selector);
        r.setConfig(c);
    }

    function test_ReactOnlySystem() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYS));
        r.react(_log(DEST, address(dst), DELIVERED_TOPIC, 1, abi.encode(uint256(0))));
    }

    // ------------------------------------------------------------------ callback guards and exactly-once

    function test_Callback_OnlyServiceProvider() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        dst.rheniumDeliver(address(r), 1, 0, abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        dst.rheniumAlarm(address(r), 1, DEST, address(dst), "");
    }

    function test_Callback_OnlyCallbackSender() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(r))
        );
        dst.rheniumDeliver(address(0xBAD), 1, 0, abi.encode(uint256(1)));
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(r))
        );
        dst.rheniumAlarm(address(0xBAD), 1, DEST, address(dst), "");
    }

    function test_Callback_ExactlyOnce_ReAcknowledges() public {
        vm.startPrank(PROXY);
        vm.expectEmit(true, false, false, true, address(dst));
        emit IRheniumCallback.Delivered(7, 0);
        dst.rheniumDeliver(address(r), 7, 0, abi.encode(uint256(1)));
        vm.expectEmit(true, false, false, true, address(dst));
        emit IRheniumCallback.Delivered(7, 1);
        dst.rheniumDeliver(address(r), 7, 1, abi.encode(uint256(1)));
        vm.stopPrank();
        assertEq(dst.executions(), 1, "executed once");
        assertTrue(dst.delivered(7));
    }

    function test_RaceTimeoutRetryVsLateOriginal_ExecutesOnce() public {
        // Original delivery is slow; timeout fires a retry; then BOTH land.
        uint256 id = _send(1_000_000, 1);
        vm.roll(block.number + 30);
        _tick();
        assertEq(r.getReceipt(id).attempts, 2);
        _pump(); // delivers attempt 0 and attempt 1
        assertEq(dst.executions(), 1);
        assertEq(uint8(_status(id)), uint8(IRheniumReactive.Status.Confirmed));
    }

    function test_FailedMethodLeavesNoAck() public {
        // Out-of-gas inside _onDelivery: no Delivered, delivered flag not set.
        vm.prank(PROXY);
        (bool ok,) = address(dst).call{gas: 60_000}(
            abi.encodeWithSelector(IRheniumCallback.rheniumDeliver.selector, address(r), 9, 0, abi.encode(uint256(50)))
        );
        assertFalse(ok);
        assertFalse(dst.delivered(9));
    }

    // ------------------------------------------------------------------ bounded tick

    function test_Tick_BoundedScan_RoundRobin() public {
        for (uint256 i = 0; i < 12; ++i) {
            _send(1_000_000, 1);
        }
        delivered = sys.reqCount(); // drop all deliveries: everything times out
        vm.roll(block.number + 30);
        _tick(); // first 8
        uint256 retried;
        for (uint256 id = 1; id <= 12; ++id) {
            if (r.getReceipt(id).attempts == 2) retried++;
        }
        assertEq(retried, 8);
        _tick(); // remaining 4 (+ the first 4 again are not yet timed out)
        retried = 0;
        for (uint256 id = 1; id <= 12; ++id) {
            if (r.getReceipt(id).attempts == 2) retried++;
        }
        assertEq(retried, 12);
    }
}

/// @notice A proxy whose overhead exceeds 100k, so a 100k request reverts with no event (as seen live).
contract StrictProxy {
    event CallbackFailure(address indexed recipient, bytes payload);

    error InsufficientGas();

    function deliver(address rvm, address target, uint64 gasLimit, bytes memory payload) external {
        if (gasLimit < 120_000) revert InsufficientGas();
        assembly {
            mstore(add(payload, 36), rvm)
        }
        (bool ok,) = target.call{gas: gasLimit - 50_000}(payload);
        if (!ok) emit CallbackFailure(target, payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
