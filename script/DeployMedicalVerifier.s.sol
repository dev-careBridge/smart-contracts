// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MedicalVerifier} from "../src/MedicalVerifier.sol";

contract DeployMedicalVerifier is Script {
    function run() external returns (MedicalVerifier) {
        vm.startBroadcast();
        MedicalVerifier medicalVerifier = new MedicalVerifier();
        vm.stopBroadcast();
        return medicalVerifier;
    }
}
