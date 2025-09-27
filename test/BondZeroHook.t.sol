// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";

import {BondZeroHook} from "../src/BondZeroHook.sol";
import {BondZeroMaster} from "../src/BondZeroMaster.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockYieldBearingToken} from "../src/mocks/MockYieldBearingToken.sol";

contract BondZeroHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    BondZeroHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    BondZeroMaster public bondZeroMaster;
    MockERC20 public underlyingAsset;
    MockYieldBearingToken public yieldBearingToken;
    uint256 public expiry;
    bool isPTToken0;

    uint256 public constant INITIAL_SUPPLY = 100 ether;
    uint256 public constant INITIAL_APR = 1000; // 10% APR (in basis points: 1000 = 10%)

    address public user1 = address(0x1);
    address public user2 = address(0x2);

    function setUp() public {
        // Deploys all required artifacts.
        deployArtifacts();

        // Bond Zero setup
        bondZeroMaster = new BondZeroMaster();
        underlyingAsset = new MockERC20("Staked ETH", "stETH", 18);
        yieldBearingToken = new MockYieldBearingToken("Wrapped Staked ETH", "wstETH", address(underlyingAsset), 1000); // 10% APR
        expiry = block.timestamp + 365 days; // 1 year from now

        underlyingAsset.mint(address(this), INITIAL_SUPPLY);
        underlyingAsset.mint(user1, INITIAL_SUPPLY);
        underlyingAsset.mint(user2, INITIAL_SUPPLY);

        // Create market
        bondZeroMaster.createBondMarket(address(yieldBearingToken), address(underlyingAsset), expiry, INITIAL_APR);
        bytes32 marketId = keccak256(abi.encode(address(yieldBearingToken), address(underlyingAsset), expiry));

        BondZeroMaster.BondMarket memory market = bondZeroMaster.getBondMarket(marketId);
        assertEq(market.yieldBearingToken, address(yieldBearingToken));

        address token0;
        address token1;

        // Token0 should be the market with lower address value
        if (market.yieldBearingToken > market.principalToken) {
            token0 = market.principalToken;
            token1 = market.yieldBearingToken;
            isPTToken0 = true;
        } else {
            token0 = market.yieldBearingToken;
            token1 = market.principalToken;
            isPTToken0 = false;
        }

        currency0 = Currency.wrap(token0);
        currency1 = Currency.wrap(token1);

        vm.label(address(token0), "Currency0");
        vm.label(address(token1), "Currency1");

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        bytes memory constructorArgs = abi.encode(poolManager, address(bondZeroMaster)); // Add all the necessary constructor arguments from the hook
        deployCodeTo("BondZeroHook.sol:BondZeroHook", constructorArgs, flags);
        hook = BondZeroHook(flags);

        // @todo Get the price of token0 in token1

        // Create the pool
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }
}
