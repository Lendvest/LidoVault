const hre = require("hardhat");

async function main() {
//   if (!process.env.DEPLOYED_CONTRACT_ADDRESS) {
//     throw new Error("Please set DEPLOYED_CONTRACT_ADDRESS in your environment");
//   }
//   if (!process.env.ROUTER_ADDRESS) {
//     throw new Error("Please set ROUTER_ADDRESS in your environment");
//   }
//   if (!process.env.DON_ID) {
//     throw new Error("Please set DON_ID in your environment");
//   }

  const CONTRACT_ADDRESS = "";
  const VAULT_ADDRESS = "";


  console.log("Starting verification process...");
  console.log("Contract Address:", CONTRACT_ADDRESS);
  console.log("Router Address:", VAULT_ADDRESS);


  try {
    // Verify the contract on Etherscan
    await hre.run("verify:verify", {
      address: CONTRACT_ADDRESS,
      constructorArguments: [
        VAULT_ADDRESS
      ],
      contract: "contracts/LVLidoVaultUtil.sol:LVLidoVaultUtil"
    });

    console.log("Contract verified successfully on Etherscan!");
  } catch (error) {
    if (error.message.includes("Already Verified")) {
      console.log("Contract is already verified on Etherscan!");
    } else {
      console.error("Error during verification:", error);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 