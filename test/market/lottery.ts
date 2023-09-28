import { ethers, getNamedAccounts, deployments } from "hardhat";

async function main() {
    const { deployer } = await getNamedAccounts();
    const signer = await ethers.getSigner(deployer);

    const LotteryDeployments = await deployments.get("Lottery");
    const Lottery = await ethers.getContractAt("Lottery", LotteryDeployments.address, signer);
    let blockHeight = 33530163;
    const result = await Lottery.getActivityInfo(3, {blockTag: blockHeight});
    console.log(`counter at block ${blockHeight}: ${result.counter}`);
}

main().then(() => {
  console.log("main: exit")
  process.exitCode = 0;
}).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});