pragma solidity ^0.8.26;

import {HookHelpers} from "./base/HookHelpers.sol";

contract DeployHook is HookHelpers {
    function run(string memory hookName, string memory feed0, string memory feed1) public {
        deployHook(hookName, feed0, feed1);
    }
}
