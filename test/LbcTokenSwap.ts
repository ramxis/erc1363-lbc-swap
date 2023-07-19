import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("LbcTokenSwap", function () {
  
  // We define a fixtures to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.

  // fixture used for tests related to 'Deployment' and 'Minting ERC1363 tokens'
  async function deployLBCSwapContractAndMithrilToken() {


    const salt = ethers.encodeBytes32String("May the force be with you");
  

    // Contracts are deployed using the first signer/account by default
    const [alice, bob, ...otherEOAs] = await ethers.getSigners();

    const initialTokenSupply = ethers.parseEther("10");
    const reserveRatio = Math.round(1 / 2 * 1000000) / 1000000; //  recall 1/2 corresponds to LBC
    const solReserveRatio = Math.floor(reserveRatio * 1000000);

    const lbcSwap = await ethers.deployContract("LbcTokenSwap", [salt,solReserveRatio,initialTokenSupply]);
    await lbcSwap.waitForDeployment();
    
    const tokenAddress = await lbcSwap.tokenAddress();
    const mithrilToken = await ethers.getContractAt("MyERC1363Token", tokenAddress);
    const swapAddress = await lbcSwap.getAddress();
    

    return { lbcSwap, mithrilToken, alice, bob, otherEOAs, swapAddress, solReserveRatio, initialTokenSupply };
  }

  // fixture used for tests related to 'Burning of ERC1363 tokens'
  async function testSetupForTokenBurn() {
    const { lbcSwap, mithrilToken, alice, otherEOAs, swapAddress ,solReserveRatio, initialTokenSupply } = await loadFixture(deployLBCSwapContractAndMithrilToken);
    
    let tx = {
      to: await lbcSwap.getAddress(),
      value: ethers.parseEther("10")
    };
    
    // send 10 ETH to the contract
    let transaction = await alice.sendTransaction(tx);
    // alice now has 10 Mithril tokens
    await transaction.wait();

    // attacker crafts another erc1363 token that he wants to the swap contract to withdraw eth 
    const attacker = otherEOAs[1];
    const tokenFactory = await ethers.getContractFactory("MyERC1363Token");
    const fakeMithrilToken = await tokenFactory.connect(attacker).deploy();
    await fakeMithrilToken.waitForDeployment();

    transaction = await fakeMithrilToken.connect(attacker).mint(attacker.address, ethers.parseEther("10"));
    await transaction.wait();

    return { lbcSwap, mithrilToken, alice, attacker, fakeMithrilToken, swapAddress, solReserveRatio, initialTokenSupply };

  }

  describe("Deployment", function () {
    it("Should deploy the mithril token and initialize parameters correctly on contract creation", async function () {
      const { lbcSwap, mithrilToken, initialTokenSupply, alice  } = await loadFixture(deployLBCSwapContractAndMithrilToken);
      // verify that lbcswap deploys the correct token
      expect(await mithrilToken.name()).to.equal("MITHRIL");
      expect(await mithrilToken.symbol()).to.equal("MIT");

      // verify that lbcswap is owner of the mithril token
      expect(await mithrilToken.owner()).to.equal(await lbcSwap.getAddress());
      expect(await mithrilToken.totalSupply()).to.equal(initialTokenSupply);

      // verify swap deployer gets initialsupply of mithril token
      expect(await mithrilToken.balanceOf(alice.address)).to.equal(initialTokenSupply);

      expect(await lbcSwap.poolBalance()).to.equal(0);
    });
  });

  describe("Minting", function () {

    it("should be able to mint new mithril tokens for user who sends eth into the swap contract", async function () {
      const { mithrilToken, alice, solReserveRatio, lbcSwap, swapAddress, initialTokenSupply } = await loadFixture(deployLBCSwapContractAndMithrilToken);
      // initial supply of mithril is 1
      expect(await mithrilToken.totalSupply()).to.equal(initialTokenSupply);

      expect(await lbcSwap.poolBalance()).to.equal(0);
      const initialaliceBalance = await mithrilToken.balanceOf(alice.address);
      expect(initialaliceBalance).to.equal(initialTokenSupply);

      const newMintedTokens = await lbcSwap.calculatePurchaseReturn(mithrilToken.totalSupply(), ethers.parseEther("10"), solReserveRatio, ethers.parseEther("10"));
    

      let tx = {
        to: swapAddress,
        value: ethers.parseEther("10")
      };
      
      // send 10 ETH to the contract
      let transaction = await alice.sendTransaction(tx);
      await transaction.wait();
    

      // pool balance should have increased
      expect(await lbcSwap.poolBalance()).to.equal(ethers.parseEther("10"));
      // total supply should have increased
      expect(await mithrilToken.totalSupply()).to.equal(initialTokenSupply + newMintedTokens);
      // alice tokens balance should have increased
      expect(await mithrilToken.balanceOf(alice.address)).to.be.equal(initialaliceBalance + newMintedTokens);

      await expect(transaction)
      .to.emit(lbcSwap, "LogMint")
      .withArgs(alice.address, newMintedTokens, ethers.parseEther("10"));

    });

    it('should mint tokens a second time correctly', async () => {
      const { mithrilToken, alice, bob, solReserveRatio, lbcSwap, swapAddress, initialTokenSupply } = await loadFixture(deployLBCSwapContractAndMithrilToken);

      const initialaliceBalance = await mithrilToken.balanceOf(alice.address);
    

      let tx = {
        to: swapAddress,
        value: ethers.parseEther("10")
      };
      
      // alice send 10 ETH to the contract as in the previous test
      let transaction = await alice.sendTransaction(tx);
      await transaction.wait();
      const tokenBalanceAfterAlice = await mithrilToken.totalSupply();

      const tokensForBob = await lbcSwap.calculatePurchaseReturn(mithrilToken.totalSupply(), ethers.parseEther("20"), solReserveRatio, ethers.parseEther("10"));

      // bob sends 10 ETH to the contract after alice
      transaction = await bob.sendTransaction(tx);
      await transaction.wait();


      const finalContractBalance = await lbcSwap.poolBalance();

      expect(finalContractBalance).to.equal(ethers.parseEther("20"));
      
      // mithril total supply should now be Alice + Bob
      expect(await mithrilToken.totalSupply()).to.equal(tokenBalanceAfterAlice + tokensForBob);

      // bobs actual token balance should be equal to our estimate
      expect(await mithrilToken.balanceOf(bob.address)).to.equal(tokensForBob);

      await expect(transaction)
      .to.emit(lbcSwap, "LogMint")
      .withArgs(bob.address, tokensForBob, ethers.parseEther("10"));
    
    });

    //TODO: remove

    // it("Should be able to mint new mithril tokens by triggiring fallback in the contract", async function () {
    //   const { mithrilToken, alice, swapAddress} = await loadFixture(deployLBCSwapContractAndMithrilToken);

    //   // initial supply of mithril is 0
    //   expect(await mithrilToken.totalSupply()).to.equal(0);

    //   const tx = {
    //     to: swapAddress,
    //     value: ethers.parseUnits("10","wei"),
    //     data: "0x4b729aff0000000000000000000000000000000000000000000000000000000000000001"
    //   };
      
    //   // send 10 wei to the contract
    //   const transaction = await alice.sendTransaction(tx);
    //   await transaction.wait();
      
    //   // mithril total supply should now be 10 bits
    //   expect(await mithrilToken.totalSupply()).to.equal(10);

    //   // alice should own 10 bits mithril tokens
    //   // mithril total supply should now be 10 bits
    //   expect(await mithrilToken.balanceOf(alice.address)).to.equal(10);

    // });

    
  });

  describe("Burning", function () {

    it("Should revert if invalid tokens are sent to the contract", async function () {
      const { swapAddress, attacker, fakeMithrilToken } = await loadFixture(testSetupForTokenBurn);
     
      await expect(fakeMithrilToken.connect(attacker).transferAndCall(swapAddress,ethers.parseEther("5"))).to.be.
      revertedWith("FORBIDDEN: mithrilToken is not the message sender");

    });

    it("Should burn mthril and transfer eth to the user", async function () {
      // const { lbcSwap, mithrilToken, alice, swapAddress } = await loadFixture(testSetupForTokenBurn);
      // const contracBalanceBeforeBurn = await ethers.provider.getBalance(swapAddress);
      // const tokenBalanceBeforeBurn = await mithrilToken.balanceOf(alice.address);


      // const tx = await mithrilToken.connect(alice).transferAndCall(swapAddress,ethers.parseEther("5"))
      // await tx.wait();
      
      // const contracBalanceAfterBurn = await ethers.provider.getBalance(swapAddress);
      // const tokenBalanceAfterBurn = await mithrilToken.balanceOf(alice.address);
  
      // await expect(tx)
      //   .to.emit(lbcSwap, "TokensReceived")
      //   .withArgs(alice.address, alice.address, ethers.parseEther("5"),"0x");
      
      // expect(contracBalanceBeforeBurn).to.equal(ethers.parseEther("10"));
      // expect(contracBalanceAfterBurn).to.equal(ethers.parseEther("5"));
      // expect(tokenBalanceBeforeBurn).to.equal(ethers.parseEther("10"));
      // expect(tokenBalanceAfterBurn).to.equal(ethers.parseEther("5"));

    });

  });
});
