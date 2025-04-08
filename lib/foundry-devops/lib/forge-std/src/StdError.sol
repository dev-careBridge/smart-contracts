// SPDX-License-Identifier: MIT
// Panics work for versions >=0.8.0, but we lowered the pragma to make this compatible with Test
pragma solidity >=0.6.2 <0.9.0;

library stderror MedicalVerifier__{
    bytes public constant assertionerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x01);
    bytes public constant arithmeticerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x11);
    bytes public constant divisionerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x12);
    bytes public constant enumConversionerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x21);
    bytes public constant encodeStorageerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x22);
    bytes public constant poperror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x31);
    bytes public constant indexOOBerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x32);
    bytes public constant memOverflowerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x41);
    bytes public constant zeroVarerror MedicalVerifier__= abi.encodeWithSignature("Panic(uint256)", 0x51);
}
