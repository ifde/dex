// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {HookFlags} from "./../../test/utils/libraries/HookFlags.sol";

import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";
import {AggregatorV2V3Interface} from "@chainlink/local/src/data-feeds/interfaces/AggregatorV2V3Interface.sol";

import {BaseScript} from "./BaseScript.sol";

import {BAHook} from "../../src/BAHookNew.sol";
import {MEVChargeHook} from "../../src/MEVChargeHook.sol";
import {PegStabilityHook} from "../../src/PegStabilityHook.sol";
import {DAHook} from "../../src/DAHook.sol";

contract HookHelpers is BaseScript {
    AggregatorV2V3Interface priceFeed0;
    AggregatorV2V3Interface priceFeed1;

    constructor() {
        deployFeeds();
    }

    function deployHook(string memory hookName, string memory feed0, string memory feed1) internal {
        address FeedAddress0 = stringToAddress(feed0);
        address FeedAddress1 = stringToAddress(feed1);

        // Use the feed address if provided
        if (FeedAddress0 != address(0)) {
            priceFeed0 = AggregatorV2V3Interface(FeedAddress0);
        }

        if (FeedAddress1 != address(0)) {
            priceFeed1 = AggregatorV2V3Interface(FeedAddress1);
        }

        bytes memory constructorArgs = abi.encode(poolManager, priceFeed0, priceFeed1);

        vm.startBroadcast();

        if (keccak256(bytes(hookName)) == keccak256(bytes("BAHook"))) {
            uint160 flags = HookFlags.BA_HOOK_FLAGS;
            (address hookAddress, bytes32 salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(BAHook).creationCode, constructorArgs);

            hookContract = new BAHook{salt: salt}(
                poolManager, AggregatorV2V3Interface(priceFeed0), AggregatorV2V3Interface(priceFeed1)
            );

            require(address(hookContract) == hookAddress, "DeployHookScript: Hook Address Mismatch");

            console.log("BAHook deployed at:", address(hookContract));
        } else if (keccak256(bytes(hookName)) == keccak256(bytes("MEVChargeHook"))) {
            uint160 flags = HookFlags.MEV_CHARGE_HOOK_FLAGS;
            (address hookAddress, bytes32 salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(MEVChargeHook).creationCode, constructorArgs);

            hookContract = new MEVChargeHook{salt: salt}(
                poolManager, AggregatorV2V3Interface(priceFeed0), AggregatorV2V3Interface(priceFeed1)
            );

            require(address(hookContract) == hookAddress, "DeployHookScript: Hook Address Mismatch");

            console.log("MEVChargeHook deployed at:", address(hookContract));
        } else if (keccak256(bytes(hookName)) == keccak256(bytes("PegStabilityHook"))) {
            uint160 flags = HookFlags.PEG_STABILITY_HOOK_FLAGS;
            (address hookAddress, bytes32 salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(PegStabilityHook).creationCode, constructorArgs);

            hookContract = new PegStabilityHook{salt: salt}(
                poolManager, AggregatorV2V3Interface(priceFeed0), AggregatorV2V3Interface(priceFeed1)
            );

            require(address(hookContract) == hookAddress, "DeployHookScript: Hook Address Mismatch");

            console.log("PegStabilityHook deployed at:", address(hookContract));
        } else if (keccak256(bytes(hookName)) == keccak256(bytes("DAHook"))) {
            uint160 flags = HookFlags.DA_HOOK_FLAGS;
            (address hookAddress, bytes32 salt) =
                HookMiner.find(CREATE2_FACTORY, flags, type(DAHook).creationCode, constructorArgs);

            hookContract = new DAHook{salt: salt}(
                poolManager, AggregatorV2V3Interface(priceFeed0), AggregatorV2V3Interface(priceFeed1)
            );

            require(address(hookContract) == hookAddress, "DeployHookScript: Hook Address Mismatch");

            console.log("DAHook deployed at:", address(hookContract));
        }

        vm.stopBroadcast();
    }

    function deployFeeds() internal {
        priceFeed0 = AggregatorV2V3Interface(address(new MockV3Aggregator(8, 300000000000))); // $3000 ETH
        priceFeed1 = AggregatorV2V3Interface(address(new MockV3Aggregator(8, 30000000))); // $0.03 SHIB
    }

    function stringToAddress(string memory str) public pure returns (address) {
        bytes memory bytesWithout0x = bytes(str);

        // Basic validation check
        if (bytesWithout0x.length != 42 || bytesWithout0x[0] != "0" || bytesWithout0x[1] != "x") {
            return address(0); // Return the zero address for invalid input
        }

        address convertedAddress;
        assembly {
            convertedAddress := div(mload(add(bytesWithout0x, 0x14)), 0x100000000000000000000000000000000)
        }

        return convertedAddress;
    }
}
