// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MedicalCrowdfunding} from "../src/MedicalCrowdfunding.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployMedicalCrowdfunding is Script {
    function deployMedicalCrowdfunding() public returns (MedicalCrowdfunding, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        vm.startBroadcast();
        MedicalCrowdfunding medicalCrowdfunding =
            new MedicalCrowdfunding(config.priceFeed, config.defaultDuration, config.i_memberDAO);
        vm.stopBroadcast();
        return (medicalCrowdfunding, helperConfig);
    }

    function run() external returns (MedicalCrowdfunding, HelperConfig) {
        return deployMedicalCrowdfunding();
    }
}
