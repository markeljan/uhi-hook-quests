// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SwapAndBridgeRouter, IOptimismStandardBridge} from "../../src/SwapAndBridgeRouter.sol";

contract SwapAndBridgeRouterForkTest is Deployers {
    address internal constant L1_BRIDGE = 0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1;
    address internal constant L1_OUTB = 0x12608ff9dac79d8443F17A4d39D93317BAD026Aa;
    address internal constant L2_OUTB = 0x7c6b91D9Be155A6Db01f749217d76fF02A7227F2;

    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);
    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );

    SwapAndBridgeRouter internal router;
    address internal recipient = makeAddr("bridge recipient");

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0, "SEPOLIA_RPC_URL required for local L1 bridge fork");
        uint256 forkBlock = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        assertEq(block.chainid, 11_155_111);
        deployFreshManagerAndRouters();
        (key,) = initPool(Currency.wrap(address(0)), Currency.wrap(L1_OUTB), IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        vm.deal(address(this), 10 ether);
        deal(L1_OUTB, address(this), 10 ether);
        IERC20Minimal(L1_OUTB).approve(address(modifyLiquidityRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 1 ether}(key, LIQUIDITY_PARAMS, ZERO_BYTES);
        router = new SwapAndBridgeRouter(manager, IOptimismStandardBridge(L1_BRIDGE), L1_OUTB, L2_OUTB);
        IERC20Minimal(L1_OUTB).approve(address(router), type(uint256).max);
    }

    function testInitiatesERC20TransferOnOfficialL1Bridge() public {
        uint256 beforeBalance = IERC20Minimal(L1_OUTB).balanceOf(L1_BRIDGE);
        vm.expectEmit(true, true, true, false, L1_BRIDGE);
        emit ERC20BridgeInitiated(L1_OUTB, L2_OUTB, address(router), recipient, 0, "");
        uint256 output = router.swap{value: 0.001 ether}(key, order(true), ZERO_BYTES);
        assertGt(output, 0);
        assertEq(IERC20Minimal(L1_OUTB).balanceOf(L1_BRIDGE) - beforeBalance, output);
    }

    function testInitiatesETHTransferOnOfficialL1Bridge() public {
        vm.expectEmit(true, true, false, false, L1_BRIDGE);
        emit ETHBridgeInitiated(address(router), recipient, 0, "");
        uint256 output = router.swap(key, order(false), ZERO_BYTES);
        assertGt(output, 0);
        assertEq(address(router).balance, 0);
    }

    function order(bool zeroForOne) internal view returns (SwapAndBridgeRouter.Order memory) {
        return SwapAndBridgeRouter.Order({
            amountIn: 0.001 ether,
            minAmountOut: 1,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
            deadline: uint48(block.timestamp + 60),
            bridgeGasLimit: 200_000,
            zeroForOne: zeroForOne,
            bridge: true,
            recipient: recipient
        });
    }
}
