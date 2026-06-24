// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeSwapExecutor} from "../src/SafeSwapExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- test doubles ---

contract TestUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

// A non-standard token whose transferFrom ignores allowance — models a malicious/buggy
// inToken (or a router with extra reach) so we can exercise the OverSpent guard.
contract PermissiveToken is ERC20 {
    constructor() ERC20("BAD", "BAD") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _transfer(from, to, amount); // no allowance check
        return true;
    }
}

// Configurable router. `swap(tokenIn, tokenOut, pullIn, pushOut)`:
//   - pulls `pullIn` of tokenIn from caller (via transferFrom) if tokenIn is ERC20
//   - sends `pushOut` of tokenOut to caller (native or ERC20)
// Native tokenIn arrives as msg.value automatically.
contract MockSwapRouter {
    address constant NATIVE = address(0);

    function swap(address tokenIn, address tokenOut, uint256 pullIn, uint256 pushOut) external payable {
        if (tokenIn != NATIVE && pullIn > 0) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), pullIn);
        }
        if (pushOut > 0) {
            if (tokenOut == NATIVE) {
                (bool ok, ) = msg.sender.call{value: pushOut}("");
                require(ok, "router: native send");
            } else {
                require(IERC20(tokenOut).transfer(msg.sender, pushOut), "router: erc20 send");
            }
        }
    }

    receive() external payable {}
}

// Concrete harness exposing the internal swap + a reentrancy guard at the entry.
contract SwapHarness is SafeSwapExecutor, ReentrancyGuard {
    address public owner;
    address public usdc;

    constructor(address _usdcToken, uint256 _slippageBps) {
        owner = msg.sender;
        usdc = _usdcToken;
        _setSlippageBps(_slippageBps);
    }

    function _swapOwner() internal view override returns (address) { return owner; }
    function _usdc() internal view override returns (address) { return usdc; }

    function setSlippage(uint256 bps) external { _setSlippageBps(bps); }

    function doSwap(
        address router,
        bytes calldata callData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external nonReentrant returns (uint256) {
        return _safeSwap(router, callData, tokenIn, tokenOut, amountIn, minOut);
    }

    receive() external payable {}
}

contract SafeSwapExecutorTest is Test {
    TestUSDC usdc;
    MockSwapRouter router;
    SwapHarness harness;

    address constant NATIVE = address(0);
    uint256 constant SLIPPAGE = 50; // 0.5%

    function setUp() public {
        usdc = new TestUSDC();
        router = new MockSwapRouter();
        harness = new SwapHarness(address(usdc), SLIPPAGE);
        harness.setRouterWhitelist(address(router), true);

        // fund harness with 10 MON (to sell) and router with USDC liquidity
        vm.deal(address(harness), 10 ether);
        usdc.mint(address(router), 1_000_000e6);
        vm.deal(address(router), 100 ether);
    }

    function _calldata(address tokenIn, address tokenOut, uint256 pullIn, uint256 pushOut)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(MockSwapRouter.swap.selector, tokenIn, tokenOut, pullIn, pushOut);
    }

    // (a) honest swap meeting minOut passes. MON -> USDC at priceE8 = 2e8 ($2/MON).
    function test_HonestSwap_Passes() public {
        uint256 amountIn = 1 ether; // 1 MON
        uint256 priceE8 = 2e8;
        uint256 minOut = harness.quoteMinOut(NATIVE, amountIn, priceE8); // ~1.99 USDC
        assertEq(minOut, 1_990_000); // 2e6 * 9950/10000

        // router pays exactly the gross 2.0 USDC -> above minOut
        bytes memory cd = _calldata(NATIVE, address(usdc), 0, 2_000_000);
        uint256 out = harness.doSwap(address(router), cd, NATIVE, address(usdc), amountIn, minOut);

        assertEq(out, 2_000_000);
        assertEq(usdc.balanceOf(address(harness)), 2_000_000);
        assertEq(address(harness).balance, 9 ether); // spent exactly 1 MON
    }

    // (b) swap returning < minOut reverts.
    function test_BelowMinOut_Reverts() public {
        uint256 amountIn = 1 ether;
        uint256 minOut = harness.quoteMinOut(NATIVE, amountIn, 2e8); // 1_990_000
        // router only pays 1.5 USDC
        bytes memory cd = _calldata(NATIVE, address(usdc), 0, 1_500_000);
        vm.expectRevert(
            abi.encodeWithSelector(SafeSwapExecutor.MinOutNotMet.selector, uint256(1_500_000), minOut)
        );
        harness.doSwap(address(router), cd, NATIVE, address(usdc), amountIn, minOut);
    }

    // (c) non-whitelisted router reverts.
    function test_NonWhitelistedRouter_Reverts() public {
        MockSwapRouter evil = new MockSwapRouter();
        usdc.mint(address(evil), 10_000e6);
        bytes memory cd = _calldata(NATIVE, address(usdc), 0, 2_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(SafeSwapExecutor.RouterNotWhitelisted.selector, address(evil))
        );
        harness.doSwap(address(evil), cd, NATIVE, address(usdc), 1 ether, 1_990_000);
    }

    // (d) router that overspends inToken reverts. Use a permissive token so the router
    //     can pull MORE than amountIn despite the exact-amountIn approval.
    function test_OverspendInToken_Reverts() public {
        PermissiveToken bad = new PermissiveToken();
        SwapHarness h = new SwapHarness(address(bad), SLIPPAGE);
        h.setRouterWhitelist(address(router), true);

        bad.mint(address(h), 100e6); // harness holds 100 BAD
        vm.deal(address(router), 100 ether);

        uint256 amountIn = 10e6; // intend to spend 10
        // router pulls 30 (overspend) and pays out 9 MON
        bytes memory cd = _calldata(address(bad), NATIVE, 30e6, 9 ether);
        uint256 minOut = 1; // ignore minOut here; we want the OverSpent branch
        vm.expectRevert(
            abi.encodeWithSelector(SafeSwapExecutor.OverSpent.selector, uint256(30e6), amountIn)
        );
        h.doSwap(address(router), cd, address(bad), NATIVE, amountIn, minOut);
    }

    // honest USDC -> MON direction also works and respects the exact approval.
    function test_HonestSwap_UsdcToMon() public {
        usdc.mint(address(harness), 10e6); // 10 USDC to spend
        uint256 amountIn = 10e6;
        uint256 priceE8 = 2e8; // $2/MON
        uint256 minOut = harness.quoteMinOut(address(usdc), amountIn, priceE8); // ~4.975 MON
        // gross = 10e6 * 1e20 / 2e8 = 5e18 ; minOut = 5e18*9950/10000 = 4.975e18
        assertEq(minOut, 4_975_000_000_000_000_000);

        bytes memory cd = _calldata(address(usdc), NATIVE, amountIn, 5 ether);
        uint256 out = harness.doSwap(address(router), cd, address(usdc), NATIVE, amountIn, minOut);
        assertEq(out, 5 ether);
        assertEq(usdc.balanceOf(address(harness)), 0);
        // allowance cleared to 0 after swap
        assertEq(usdc.allowance(address(harness), address(router)), 0);
    }

    function test_SetRouterWhitelist_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("swap: not owner"));
        harness.setRouterWhitelist(address(0x1234), true);
    }
}
