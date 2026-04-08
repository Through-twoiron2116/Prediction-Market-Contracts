// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ConditionalTokens} from "../../src/CTF/ConditionalTokens.sol";
import {CTFExchange} from "../../src/exchange/CTFExchange.sol";
import {Vault} from "../../src/neg-risk/Vault.sol";
import {NegRiskAdapter} from "../../src/neg-risk/NegRiskAdapter.sol";
import {NegRiskOperator} from "../../src/neg-risk/NegRiskOperator.sol";
import {NegRiskCTFExchange} from "../../src/neg-risk/NegRiskCTFExchange.sol";
import {NegRiskFeeModule} from "../../src/neg-risk/NegRiskFeeModule.sol";
import {OptimisticOracle} from "../../src/oracle/OptimisticOracle.sol";

/**
 * @title Deploy
 * @notice Full-stack deployment of the Polymarket-style prediction market system.
 *
 * Prerequisites (set in .env):
 *   PRIVATE_KEY        - deployer private key
 *   COLLATERAL_ADDRESS - USDC address on target chain
 *   FEE_RECEIVER       - address to receive exchange fees
 *   ORACLE_ADDRESS     - off-chain oracle address for NegRiskOperator
 *
 * Usage:
 *   forge script script/deploy/Deploy.s.sol --rpc-url arbitrum --broadcast --verify
 *   forge script script/deploy/Deploy.s.sol --rpc-url abstract  --broadcast --verify
 */
contract Deploy is Script {
    // Populated during run()
    ConditionalTokens public ctf;
    CTFExchange public ctfExchange;
    Vault public vault;
    NegRiskAdapter public negRiskAdapter;
    NegRiskOperator public negRiskOperator;
    NegRiskCTFExchange public negRiskCTFExchange;
    NegRiskFeeModule public negRiskFeeModule;
    OptimisticOracle public oracle;

    function run() external {
        address collateral = vm.envAddress("COLLATERAL_ADDRESS");
        address feeReceiver = vm.envAddress("FEE_RECEIVER");
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Deploying Polymarket Stack ===");
        console2.log("Chain ID:    ", block.chainid);
        console2.log("Deployer:    ", deployer);
        console2.log("Collateral:  ", collateral);
        console2.log("FeeReceiver: ", feeReceiver);

        vm.startBroadcast(deployerKey);

        // 1. Core CTF
        ctf = new ConditionalTokens();
        console2.log("ConditionalTokens:", address(ctf));

        // 2. Binary market exchange
        ctfExchange = new CTFExchange(collateral, address(ctf), feeReceiver);
        console2.log("CTFExchange:      ", address(ctfExchange));

        // 3. Vault (fee accumulator for neg-risk)
        vault = new Vault();
        console2.log("Vault:            ", address(vault));

        // 4. NegRisk adapter
        negRiskAdapter = new NegRiskAdapter(address(ctf), collateral, address(vault));
        console2.log("NegRiskAdapter:   ", address(negRiskAdapter));

        // 5. NegRisk operator (admin layer over adapter)
        negRiskOperator = new NegRiskOperator(address(negRiskAdapter));
        negRiskOperator.setOracle(oracleAddress);
        console2.log("NegRiskOperator:  ", address(negRiskOperator));

        // 6. NegRisk exchange (uses wrapped collateral from adapter)
        address wcol = address(negRiskAdapter.wcol());
        negRiskCTFExchange = new NegRiskCTFExchange(wcol, address(ctf), address(negRiskAdapter), feeReceiver);
        console2.log("NegRiskCTFExchange:", address(negRiskCTFExchange));

        // 7. Fee module
        negRiskFeeModule = new NegRiskFeeModule(
            address(negRiskCTFExchange),
            address(negRiskAdapter),
            address(ctf)
        );
        console2.log("NegRiskFeeModule: ", address(negRiskFeeModule));

        // 8. Optimistic oracle (resolves CTF conditions)
        oracle = new OptimisticOracle(address(ctf));
        console2.log("OptimisticOracle: ", address(oracle));

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        _printAddresses();
    }

    function _printAddresses() internal view {
        console2.log("\n--- Contract Addresses ---");
        console2.log("CTF:               ", address(ctf));
        console2.log("CTFExchange:       ", address(ctfExchange));
        console2.log("Vault:             ", address(vault));
        console2.log("NegRiskAdapter:    ", address(negRiskAdapter));
        console2.log("NegRiskOperator:   ", address(negRiskOperator));
        console2.log("NegRiskCTFExchange:", address(negRiskCTFExchange));
        console2.log("NegRiskFeeModule:  ", address(negRiskFeeModule));
        console2.log("OptimisticOracle:  ", address(oracle));
    }
}
