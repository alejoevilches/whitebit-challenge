import { ethers } from "hardhat";

async function main() {
  console.log("Deploying contracts...");

  const ReputationSystem = await ethers.getContractFactory("ReputationSystem");
  const reputationSystem = await ReputationSystem.deploy();
  await reputationSystem.waitForDeployment();
  const repAddress = await reputationSystem.getAddress();
  console.log("ReputationSystem:", repAddress);

  const PredictionMarket = await ethers.getContractFactory("PredictionMarket");
  const predictionMarket = await PredictionMarket.deploy(repAddress);
  await predictionMarket.waitForDeployment();
  const marketAddress = await predictionMarket.getAddress();
  console.log("PredictionMarket:", marketAddress);

  const WorldCupBetting = await ethers.getContractFactory("WorldCupBetting");
  const worldCupBetting = await WorldCupBetting.deploy(repAddress);
  await worldCupBetting.waitForDeployment();
  const worldCupBettingAddress = await worldCupBetting.getAddress();
  console.log("WorldCupBetting:", worldCupBettingAddress);

  await reputationSystem.setPredictionMarket(worldCupBettingAddress);
  console.log("Connected ReputationSystem to WorldCupBetting");

  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdc = await MockERC20.deploy("Mock USDC", "USDC");
  await usdc.waitForDeployment();
  const usdcAddress = await usdc.getAddress();
  console.log("Mock USDC:", usdcAddress);

  console.log("\n=== SAVE THESE ADDRESSES ===");
  console.log("NEXT_PUBLIC_PREDICTION_MARKET_ADDRESS=", marketAddress);
  console.log("NEXT_PUBLIC_WORLD_CUP_BETTING_ADDRESS=", worldCupBettingAddress);
  console.log("NEXT_PUBLIC_REPUTATION_SYSTEM_ADDRESS=", repAddress);
  console.log("NEXT_PUBLIC_MOCK_USDC_ADDRESS=", usdcAddress);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
