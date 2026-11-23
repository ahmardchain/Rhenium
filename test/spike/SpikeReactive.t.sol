// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {SpikeReactive} from "../../src/spike/SpikeReactive.sol";

/// Records subscribe / unsubscribe / requestCallbackV_1_0 calls made to the system contract address.
contract MockSystem {
    event Sub(uint256 chainId, address c, uint256 t0, uint256 t1);
    event Unsub(uint256 chainId, address c, uint256 t0, uint256 t1);
    event Req(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256, uint256) external {
        emit Sub(c, a, t0, t1);
    }

    function unsubscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256, uint256) external {
        emit Unsub(c, a, t0, t1);
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        emit Req(c.chainId, c.recipient, c.gasLimit, c.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
    receive() external payable {}
}

contract SpikeReactiveTest is Test {
    address constant SYS = 0x8888888888888888888888888888888888888888;
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address constant ORIGIN = address(0xA11CE);
    address constant CB = address(0xCB);
    SpikeReactive r;

    function setUp() public {
        vm.etch(SYS, address(new MockSystem()).code);
        r = new SpikeReactive(84532, ORIGIN, 84532, PROXY);
        r.setCallback(CB);
    }

    function _log(address c, uint256 t0, uint256 t1, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = c == address(0xfffFfF) ? 5318007 : 84532;
        l.contractAddress = c;
        l.topic0 = t0;
        l.topic1 = t1;
        l.data = data;
        l.txHash = 0xdead;
    }

    function test_pingFailRetryConfirm() public {
        vm.startPrank(SYS);
        r.react(
            _log(
                ORIGIN,
                uint256(keccak256("Ping(uint256,uint256,uint256)")),
                7,
                abi.encode(uint256(100_000), uint256(10))
            )
        );
        (uint64 g, uint32 a,, uint8 s,) = r.ps(7);
        assertEq(g, 100_000);
        assertEq(a, 0);
        assertEq(s, 1);
        assertTrue(r.cronOn());

        // Proxy-reported failure carrying the payload (rvm overwritten by proxy, so any address)
        bytes memory payload = abi.encodeWithSignature("onPing(address,uint256,uint256,uint256)", address(r), 7, 0, 10);
        vm.recordLogs();
        r.react(
            _log(PROXY, uint256(keccak256("CallbackFailure(address,bytes)")), uint256(uint160(CB)), abi.encode(payload))
        );
        (g, a,, s,) = r.ps(7);
        assertEq(a, 1);
        assertEq(g, 300_000);
        assertEq(s, 1);

        // Stale failure for attempt 0 again is ignored
        r.react(
            _log(PROXY, uint256(keccak256("CallbackFailure(address,bytes)")), uint256(uint160(CB)), abi.encode(payload))
        );
        (, a,,,) = r.ps(7);
        assertEq(a, 1);

        r.react(
            _log(CB, uint256(keccak256("Delivered(uint256,uint256,uint256)")), 7, abi.encode(uint256(1), uint256(0)))
        );
        (,,, s,) = r.ps(7);
        assertEq(s, 2);
        assertEq(r.pending(), 0);

        // Next cron tick with nothing pending switches cron off
        r.react(
            _log(
                address(0xfffFfF),
                0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687,
                0,
                abi.encode(block.number)
            )
        );
        assertFalse(r.cronOn());
        vm.stopPrank();
    }

    function test_timeoutRetry() public {
        vm.startPrank(SYS);
        r.react(
            _log(
                ORIGIN, uint256(keccak256("Ping(uint256,uint256,uint256)")), 1, abi.encode(uint256(200_000), uint256(1))
            )
        );
        vm.roll(block.number + 121);
        r.react(
            _log(
                address(0xfffFfF),
                0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687,
                0,
                abi.encode(block.number)
            )
        );
        (uint64 g, uint32 a,,,) = r.ps(1);
        assertEq(a, 1);
        assertEq(g, 400_000);
        vm.stopPrank();
    }

    function test_onlySystem() public {
        vm.expectRevert();
        r.react(_log(ORIGIN, 1, 1, ""));
    }
}
