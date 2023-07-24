import { ethers } from "hardhat";

async function main() {
  const currentTimestampInSeconds = Math.round(Date.now() / 1000);
  const unlockTime = currentTimestampInSeconds + 60;

  const salt = ethers.encodeBytes32String("May the force be with you");
  const initialTokenSupply = ethers.parseEther("10");
  const reserveRatio = Math.round(1 / 2 * 1000000) / 1000000; //  recall 1/2 corresponds to LBC
  const solReserveRatio = Math.floor(reserveRatio * 1000000);
  let defaultGasPrice = ethers.parseUnits("30","gwei");

  const LbcTokenSwap = await ethers.deployContract("LbcTokenSwap", [salt,solReserveRatio,initialTokenSupply, defaultGasPrice]);

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
