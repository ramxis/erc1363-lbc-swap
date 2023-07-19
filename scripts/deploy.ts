import { ethers } from "hardhat";

async function main() {
  const currentTimestampInSeconds = Math.round(Date.now() / 1000);
  const unlockTime = currentTimestampInSeconds + 60;

  const salt = ethers.encodeBytes32String("May the force be with you");

  const LbcTokenSwap = await ethers.deployContract("v", [salt]);

  await LbcTokenSwap.waitForDeployment();

  console.log(
    `LbcTokenSwap contract was deployed to ${LbcTokenSwap.target}`
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
