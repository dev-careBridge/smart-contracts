forge script script/DeployMedicalVerifier.s.sol:DeployMedicalVerifier --rpc-url $ARBITRUM_RPC_URL --broadcast --verify --etherscan-api-key $ARBISCAN_API_KEY --private-key 0xb4f5dd6e8ca877bee85b5c54ce9adf52184f46d848b1ae0f5e84b4277b17bf23 -vvvv


cat out/MedicalVerifier.sol/MedicalVerifier.json | jq .abi > abi.json
