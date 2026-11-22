// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {RheniumReactive} from "../src/RheniumReactive.sol";
import {IRheniumReactive} from "../src/IRhenium.sol";
import {MockUSD} from "../src/demo/MockUSD.sol";
import {Payer} from "../src/demo/Payer.sol";
import {RheniumPayee, NaivePayee} from "../src/demo/Payees.sol";
import {NaivePaymentReactive, RheniumPaymentReactive} from "../src/demo/PaymentReactives.sol";
import {MockSystem, MockProxy} from "./utils/Mocks.sol";

/// Proxy reverting below 120k with no event (as observed live) and keeping 100k for itself otherwise.
contract LiveLikeProxy {
    event CallbackFailure(address indexed recipient, bytes payload);

    error InsufficientGas();

    function deliver(address rvm, address target, uint64 gasLimit, bytes memory payload) external {
        if (gasLimit < 120_000) revert InsufficientGas();
        assembly {
            mstore(add(payload, 36), rvm)
        }
        (bool ok,) = target.call{gas: gasLimit - 100_000}(payload);
        if (!ok) emit CallbackFailure(target, payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract DemoTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant BASE_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address constant UNI_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
    address constant CRON = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant BASE = 84532;
    uint256 constant UNI = 1301;
    uint256 constant PAYMENT_REQUESTED_TOPIC =
        uint256(keccak256("PaymentRequested(uint256,address,uint256,uint64,address)"));
    uint256 constant DELIVERED_TOPIC = uint256(keccak256("Delivered(uint256,uint256)"));
    uint256 constant FAILURE_TOPIC = uint256(keccak256("CallbackFailure(address,bytes)"));

    MockSystem sys;
    MockUSD usdBase;
    MockUSD usdUni;
    Payer naivePayer;
    Payer rhPayer;
    NaivePayee naivePayee;
    RheniumPayee rhPayee;
    NaivePaymentReactive naive;
    RheniumPaymentReactive rh;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    uint256 pumped;

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        vm.etch(BASE_PROXY, address(new MockProxy()).code);
        vm.etch(UNI_PROXY, address(new LiveLikeProxy()).code);
        sys = MockSystem(payable(SYS));

        RheniumReactive.Config memory c;
        c.maxAttempts = 4;
        c.gasStep = 100_000;
        c.maxGasLimit = 600_000;
        c.timeoutBlocks = 20;
        c.cronTopic = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687; // Cron10
        c.cronEnabled = true;

        // 1. reactive contracts first
        naive = new NaivePaymentReactive(BASE, UNI);
        rh = new RheniumPaymentReactive(BASE, UNI, c);
        // 2. origin + destination contracts, each authorising its reactive
        usdBase = new MockUSD();
        usdUni = new MockUSD();
        naivePayer = new Payer(usdBase, IPayable(payable(BASE_PROXY)), address(naive));
        rhPayer = new Payer(usdBase, IPayable(payable(BASE_PROXY)), address(rh));
        naivePayee = new NaivePayee(usdUni, IPayable(payable(UNI_PROXY)), address(naive));
        rhPayee = new RheniumPayee(usdUni, IPayable(payable(UNI_PROXY)), address(rh));
        // 3. link
        naive.link(address(naivePayer), address(naivePayee));
        rh.link(address(rhPayer), address(rhPayee), 200_000);
        // liquidity + payer balance
        usdUni.mint(address(naivePayee), 1_000e6);
        usdUni.mint(address(rhPayee), 1_000e6);
        usdBase.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdBase.approve(address(naivePayer), type(uint256).max);
        usdBase.approve(address(rhPayer), type(uint256).max);
        vm.stopPrank();
    }

    function _log(uint256 chainId, address c, uint256 t0, uint256 t1, uint256 t2, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = chainId;
        l.contractAddress = c;
        l.topic0 = t0;
        l.topic1 = t1;
        l.topic2 = t2;
        l.data = data;
    }

    /// Alice pays on Base; forward the PaymentRequested log to `target` reactive.
    function _pay(Payer payer, address target, uint64 gas) internal returns (uint256 id) {
        vm.recordLogs();
        vm.prank(alice);
        id = payer.pay(bob, 25e6, gas);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory lg = logs[logs.length - 1];
        vm.prank(SYS);
        IReactive(payable(target))
            .react(
                _log(BASE, address(payer), uint256(lg.topics[0]), uint256(lg.topics[1]), uint256(lg.topics[2]), lg.data)
            );
    }

    /// Deliver pending callback requests through the right proxy; feed Delivered/CallbackFailure back to `target`.
    function _pump(address target) internal {
        for (; pumped < sys.reqCount(); ++pumped) {
            MockSystem.Req memory q = sys.req(pumped);
            address proxy = q.chainId == UNI ? UNI_PROXY : BASE_PROXY;
            vm.recordLogs();
            try MockProxy(payable(proxy)).deliver(q.sender, q.recipient, q.gasLimit, q.payload) {} catch {}
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i = 0; i < logs.length; ++i) {
                uint256 t0 = uint256(logs[i].topics[0]);
                if (t0 != DELIVERED_TOPIC && t0 != FAILURE_TOPIC) continue;
                if (q.sender != target) continue;
                vm.prank(SYS);
                IReactive(payable(target))
                    .react(_log(q.chainId, logs[i].emitter, t0, uint256(logs[i].topics[1]), 0, logs[i].data));
            }
        }
    }

    function _tick(address target) internal {
        vm.prank(SYS);
        IReactive(payable(target))
            .react(_log(5318007, CRON, 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687, 0, 0, ""));
    }

    function test_Naive_SilentlyLosesPayment() public {
        _pay(naivePayer, address(naive), 100_000);
        _pump(address(naive));
        assertEq(usdUni.balanceOf(bob), 0, "bob unpaid");
        assertEq(usdBase.balanceOf(alice), 975e6, "alice's money is escrowed");
        // ...and nothing anywhere tells alice. The naive reactive has no state that could.
    }

    function test_Rhenium_RecoversAndConfirms() public {
        _pay(rhPayer, address(rh), 100_000); // same too-low gas
        _pump(address(rh)); // attempt 0 reverts in the proxy: no event
        assertEq(usdUni.balanceOf(bob), 0);
        uint256 rid = rh.receiptOfPayment(1);
        assertEq(uint8(rh.getReceipt(rid).status), uint8(IRheniumReactive.Status.Pending));
        vm.roll(block.number + 20);
        _tick(address(rh)); // timeout -> retry at 200k
        _pump(address(rh));
        assertEq(usdUni.balanceOf(bob), 25e6, "bob paid");
        RheniumReactive.Receipt memory r = rh.getReceipt(rid);
        assertEq(uint8(r.status), uint8(IRheniumReactive.Status.Confirmed));
        assertEq(r.attempts, 2);
        assertFalse(rh.cronSubscribed(), "idle again");
    }

    function test_Rhenium_FailureEventPath() public {
        // 125k clears the proxy check but forwards only 25k: the payout runs out of gas -> CallbackFailure.
        _pay(rhPayer, address(rh), 125_000);
        _pump(address(rh)); // CallbackFailure -> retry at 225k (125k forwarded) -> paid
        assertEq(usdUni.balanceOf(bob), 25e6);
        assertEq(rh.getReceipt(rh.receiptOfPayment(1)).attempts, 2);
    }

    function test_Rhenium_GivesUp_RefundsPayer() public {
        // Payee has no liquidity: every attempt reverts. After 4 attempts the payer is refunded on Base.
        vm.prank(address(rhPayee));
        usdUni.transfer(address(1), 1_000e6);
        _pay(rhPayer, address(rh), 200_000);
        _pump(address(rh));
        uint256 rid = rh.receiptOfPayment(1);
        assertEq(uint8(rh.getReceipt(rid).status), uint8(IRheniumReactive.Status.Failed));
        assertEq(usdBase.balanceOf(alice), 1_000e6, "alice refunded via alarm");
        (,,, Payer.State st) = rhPayer.payments(1);
        assertEq(uint8(st), uint8(Payer.State.Refunded));
    }

    function test_PayerRejectsDelivery_and_ForeignAlarm() public {
        vm.prank(BASE_PROXY);
        vm.expectRevert();
        rhPayer.rheniumDeliver(address(rh), 1, 0, "");
        vm.prank(BASE_PROXY);
        vm.expectRevert(); // naive reactive is not authorised on the Rhenium payer
        rhPayer.rheniumAlarm(address(naive), 1, UNI, address(rhPayee), abi.encode(uint256(1), bob, uint256(1)));
    }
}
