import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { parseUnits } from "ethers";
import { ethers } from "hardhat";
import { expect } from "chai";

describe("ERC20Rebasing", () => {
   async function deployFixture() {
    const [, user1, user2, user3] = await ethers.getSigners();

    const MockERC20Rebasing = await ethers.getContractFactory("TestERC20Rebasing");
    const token = await MockERC20Rebasing.deploy();

    return { token, user1, user2, user3 };
   }

   type DeployFixture = Awaited<ReturnType<typeof deployFixture>>;

   describe("Deployment", () => {
     it("TotalBalance zero", async () => {
        const { token } = await loadFixture(deployFixture);
        expect(await token.totalSupply()).to.equal(0);
    });
    it("Account Balance zero", async () => {
        const { token, user1 } = await loadFixture(deployFixture);
        expect(await token.balanceOf(user1.address)).to.equal(0);
    });
   });

   describe("Normal ERC20", () => {
    it("Minting", async () => {
        const { token, user1 } = await loadFixture(deployFixture);
        await token.mint(user1.address, 100);
        expect(await token.balanceOf(user1.address)).to.equal(100);
        expect(await token.totalSupply()).to.equal(100);
    });
    it("Transfer", async () => {
        const { token, user1, user2 } = await loadFixture(deployFixture);
        await token.mint(user1.address, 100);

        expect(await token.connect(user1).transfer(user2.address, 50))
            .to.changeTokenBalances(token, [user1, user2], [-50, 50]);
        
        expect(await token.balanceOf(user1.address)).to.equal(50);
        expect(await token.balanceOf(user2.address)).to.equal(50);
        expect(await token.totalSupply()).to.equal(100);
    });
    it("Burning", async () => {
        const { token, user1, user2 } = await loadFixture(deployFixture);
        await token.mint(user1.address, 100);
        await token.mint(user2.address, 50);
        
        expect(await token.burn(user1.address, 50))
            .to.changeTokenBalances(token, [user1], [-50]);
        
        expect(await token.balanceOf(user1.address)).to.equal(50);
        expect(await token.balanceOf(user2.address)).to.equal(50);
        expect(await token.totalSupply()).to.equal(100);
    });
   });
  describe("Rebasing", () => {
    it("Rebasing", async () => {
        const { token, user1, user2 } = await loadFixture(deployFixture);
        await token.mint(user1.address, 200);
        await token.mint(user2.address, 100);

        await token.rebase(30);

        expect(await token.balanceOf(user1.address)).to.approximately(220, 1);
        expect(await token.balanceOf(user2.address)).to.approximately(110, 1);
    });
  });
  describe("Attacks", () => {
    it("1 wei mint with large rebase", async () => {
        const { token, user1, user2 } = await loadFixture(deployFixture);
        await token.mint(user1.address, 1);
        await token.rebase(parseUnits("200", 18));

        // user2 mint 100 tokens
        await token.mint(user2.address, parseUnits("100", 18));

        // user1 can not steal user2's tokens
        const user1Balance = await token.balanceOf(user1.address);
        expect(user1Balance).to.lessThan(parseUnits("200", 18))
        await token.burn(user1.address, user1Balance);

        await token.rebase(1);

        expect(await token.balanceOf(user1.address)).to.equal(0);
        expect(await token.balanceOf(user2.address)).to.approximately(parseUnits("100", 18), 1);
    });
  });
  describe("Rounding", () => {
    it("Rouding error when transfer", async () => {
        const { token, user1, user2 } = await loadFixture(deployFixture);

        await token.mint(user1.address, 1000);
        
        await token.rebase(2000);
        // 1 share = 3 token

        // 3 rounds down
        await token.connect(user1).transfer(user2.address, 2);
        await token.connect(user1).transfer(user2.address, 2);
        await token.connect(user1).transfer(user2.address, 2);

        // still enough shares to transfer all tokens
        await token.connect(user2).transfer(user1.address, 6);

        expect(await token.balanceOf(user2.address)).to.equal(0);
        await token.rebase(1);
        expect(await token.balanceOf(user2.address)).to.equal(0);
    });
  });
});
