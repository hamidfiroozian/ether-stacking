// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");
const { owner, ownerPub } = require("./../secrets.json");


async function main() {
  console.log('owner', owner)
  console.log('ownerPub', ownerPub)


  // We get the contract to deploy
  const NFT = await hre.ethers.getContractFactory("Yieldly");
  const nft = await NFT.deploy();

  await nft.deployed();
  console.log("NFT deployed to:", nft.address);



  // We get the contract to deploy
  const WMatic = await hre.ethers.getContractFactory(
    "WMATIC"
  );
  const WMaticAddress = await WMatic.deploy();
  console.log("WMatic deployed to:", WMaticAddress.address);


  // We get the contract to deploy
  const Marketplace = await hre.ethers.getContractFactory(
    "YieldlyMarketplace"
  );
  console.log("Going to deploy .........................")
  const marketplace = await Marketplace.deploy(
    WMaticAddress.address,
    ownerPub
  );
  console.log("Contract Created .........................")


  await marketplace.deployed();
  console.log("Marketplace deployed to:", marketplace.address);

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
