import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("LbcTokenSwap", function () {

  // We define a fixtures to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.

  // fixture used for tests related to "Deployment" and "Minting ERC1363 tokens"
  async function deployLBCSwapContractAndMithrilToken() {


    const salt = ethers.encodeBytes32String("May the force be with you");
  

    // Contracts are deployed using the first signer/account by default
    const [alice, bob, ...otherEOAs] = await ethers.getSigners();

    const initialTokenSupply = ethers.parseEther("10");
    const reserveRatio = Math.round(1 / 2 * 1000000) / 1000000; //  recall 1/2 corresponds to LBC
    const solReserveRatio = Math.floor(reserveRatio * 1000000);
    let defaultGasPrice = ethers.parseUnits("30","gwei");

    const lbcSwap = await ethers.deployContract("LbcTokenSwap", [salt,solReserveRatio,initialTokenSupply, defaultGasPrice]);
    await lbcSwap.waitForDeployment();
    
    const tokenAddress = await lbcSwap.tokenAddress();
    const mithrilToken = await ethers.getContractAt("MyERC1363Token", tokenAddress);
    const swapAddress = await lbcSwap.getAddress();
    

    return { lbcSwap, mithrilToken, alice, bob, otherEOAs, swapAddress, solReserveRatio, initialTokenSupply, defaultGasPrice };
  }

  // fixture used for tests related to "Burning of ERC1363 tokens"
  async function testSetupForTokenBurn() {
    const { lbcSwap, mithrilToken, alice, bob, otherEOAs, swapAddress ,solReserveRatio, initialTokenSupply, defaultGasPrice } = await loadFixture(deployLBCSwapContractAndMithrilToken);
    
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

    return { lbcSwap, mithrilToken, alice, bob, attacker, fakeMithrilToken, swapAddress, solReserveRatio, initialTokenSupply, defaultGasPrice };

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

    it("should set alice as its owner", async function () {
      const { lbcSwap, alice  } = await loadFixture(deployLBCSwapContractAndMithrilToken);
      // verify alice is the contract owner
      expect(await lbcSwap.owner()).to.equal(alice.address);
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

    it("should mint tokens a second time correctly", async () => {
      const { mithrilToken, alice, bob, solReserveRatio, lbcSwap, swapAddress } = await loadFixture(deployLBCSwapContractAndMithrilToken);
    
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

    it("should be able to accept large amount of eth and mint tokens", async () => {

      const { mithrilToken, alice, bob, solReserveRatio, lbcSwap, swapAddress } = await loadFixture(deployLBCSwapContractAndMithrilToken);

      let tx = {
        to: swapAddress,
        value: ethers.parseEther("10")
      };
      
      // alice send 10 ETH to the contract as in the previous test
      let transaction = await alice.sendTransaction(tx);
      await transaction.wait();

      tx = {
        to: swapAddress,
        value: ethers.parseEther("9000")
      };

      // bob sends 9000 ETH to the contract after alice, pushing the price higher
      transaction = await bob.sendTransaction(tx);
      await transaction.wait();


      const finalContractBalance = await lbcSwap.poolBalance();

      expect(finalContractBalance).to.equal(ethers.parseEther("9010"));
      
      // mithril total supply should now be Alice + Bob
      const userMithrilBalance = (await mithrilToken.balanceOf(alice.address)) 
      + (await mithrilToken.balanceOf(bob.address));
      
      expect(await mithrilToken.totalSupply()).to.equal(userMithrilBalance);

      await expect(transaction).to.emit(lbcSwap, "LogMint");

    });

    it("should not be able to mint anything with 0 ETH", async () => {
      const { alice, swapAddress } = await loadFixture(deployLBCSwapContractAndMithrilToken);
    
      let tx = {
        to: swapAddress,
        value: 0
      };
      
      await expect(alice.sendTransaction(tx)).to.be.
      revertedWith("FORBIDDEN: only nonzero eth values are accepted");

    });
    
  });

  describe("Burning", function () {

    it("Should revert if invalid tokens are sent to the contract", async function () {
      const { swapAddress, attacker, fakeMithrilToken } = await loadFixture(testSetupForTokenBurn);
     
      await expect(fakeMithrilToken.connect(attacker).transferAndCall(swapAddress,ethers.parseEther("5"))).to.be.
      revertedWith("FORBIDDEN: mithrilToken is not the message sender");

    });

    it("Should burn mthril and transfer eth to the user", async function () {
      const { lbcSwap, mithrilToken, alice, swapAddress } = await loadFixture(testSetupForTokenBurn);
      const contracBalanceBeforeBurn = await ethers.provider.getBalance(swapAddress);
      const tokenBalanceBeforeBurn = await mithrilToken.balanceOf(alice.address);
      const mithrilTokenSupplyBeforeBurn = await mithrilToken.totalSupply();
      const aliceEthBalanceBeforeBurn = await ethers.provider.getBalance(alice.address);


      const tx = await mithrilToken.connect(alice).transferAndCall(swapAddress,ethers.parseEther("5"))
      await tx.wait();
      
      const contracBalanceAfterBurn = await ethers.provider.getBalance(swapAddress);
      const tokenBalanceAfterBurn = await mithrilToken.balanceOf(alice.address);
      const mithrilTokenSupplyAfterBurn = await mithrilToken.totalSupply();
      const aliceEthBalanceAfterBurn = await ethers.provider.getBalance(alice.address);
  
      await expect(tx)
        .to.emit(lbcSwap, "TokensReceived")
        .withArgs(alice.address, alice.address, ethers.parseEther("5"));
      
      expect(contracBalanceBeforeBurn).to.equal(ethers.parseEther("10"));
      expect(contracBalanceAfterBurn).to.be.below(contracBalanceBeforeBurn);
      expect(tokenBalanceAfterBurn).to.be.below(tokenBalanceBeforeBurn);
      expect(mithrilTokenSupplyAfterBurn).to.be.below(mithrilTokenSupplyBeforeBurn);

      // alice eth balance should increase after the burn
      expect(aliceEthBalanceAfterBurn).to.be.above(aliceEthBalanceBeforeBurn);
      await expect(tx).to.emit(lbcSwap, "LogBurn");

    });

    it("Should burn mthril and transfer all eth to the user", async function () {
      const { lbcSwap, mithrilToken, alice, swapAddress } = await loadFixture(testSetupForTokenBurn);
      const contracBalanceBeforeBurn = await ethers.provider.getBalance(swapAddress);
      const aliceMithBalanceBeforeBurn = await mithrilToken.balanceOf(alice.address);
      const aliceEthBalanceBeforeBurn = await ethers.provider.getBalance(alice.address);

      expect(contracBalanceBeforeBurn).to.equal(ethers.parseEther("10"));
      const tx = await mithrilToken.connect(alice).transferAndCall(swapAddress,aliceMithBalanceBeforeBurn)
      await tx.wait();
     
      const contracBalanceAfterBurn = await ethers.provider.getBalance(swapAddress);
      const aliceMithBalanceAfterBurn = await mithrilToken.balanceOf(alice.address);
      const mithrilTokenSupplyAfterBurn = await mithrilToken.totalSupply();
      const aliceEthBalanceAfterBurn = await ethers.provider.getBalance(alice.address);
  
      await expect(tx)
        .to.emit(lbcSwap, "TokensReceived")
        .withArgs(alice.address, alice.address, aliceMithBalanceBeforeBurn);
      
      expect(contracBalanceAfterBurn).to.be.equal(0);
      expect(aliceMithBalanceAfterBurn).to.be.equal(0);
      expect(mithrilTokenSupplyAfterBurn).to.be.equal(0);
      expect(aliceEthBalanceAfterBurn).to.be.above(aliceEthBalanceBeforeBurn)
      await expect(tx).to.emit(lbcSwap, "LogBurn");

    });

  });

  describe("Setting gas price", function () {

    it("Should be able to set gas price", async function () {
      const { lbcSwap, alice, } = await loadFixture(deployLBCSwapContractAndMithrilToken);

      const tx = await lbcSwap.connect(alice).setGasPrice(ethers.parseUnits("20000", "gwei"));
      await tx.wait();
      const newGasPrice = await lbcSwap.gasPrice();

      expect(newGasPrice).to.equal(ethers.parseUnits("20000", "gwei"));

    });

    it("Should not be able to set zero as gas price", async function () {
      const { lbcSwap, alice, } = await loadFixture(deployLBCSwapContractAndMithrilToken);

      await expect(lbcSwap.connect(alice).setGasPrice(ethers.parseUnits("0", "gwei"))).to.be
      .revertedWith("FORBIDDEN: gas price cannot be zero");

    });

    it("Should not be able to change gasPrice if caller is not owner", async function () {
      const { lbcSwap, alice, bob } = await loadFixture(deployLBCSwapContractAndMithrilToken);

      await expect(lbcSwap.connect(bob).setGasPrice(ethers.parseUnits("0", "gwei"))).to.be
      .revertedWith("Ownable: caller is not the owner");

    });

  });

  describe("Front running should be mititgated", function () {

    it("Should revert when attempting to mint with gas price higher then set in the swap contract", async function () {
      const { swapAddress, bob, defaultGasPrice } = await loadFixture(deployLBCSwapContractAndMithrilToken);
    
      let tx = {
        to: swapAddress,
        value: 10,
        gasPrice: defaultGasPrice + ethers.parseUnits("20", "gwei"),
      };
      
      await expect(bob.sendTransaction(tx)).to.be.
      revertedWith("FORBIDDEN: Invalid gas price");

    });

  });

});
