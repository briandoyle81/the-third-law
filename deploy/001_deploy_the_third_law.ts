import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ethers } from "hardhat";

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deploy } = hre.deployments;
  // We can now use deployer
  const { deployer } = await hre.getNamedAccounts();

  await deploy("TheThirdLaw", {
    from: deployer,
  });
};

export default func;

// This tag will help us in the next section to trigger this deployment file programmatically
func.tags = ["DeployAll"];
