import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

//import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests ERC20 transfers', async() => {
  const [owner, alice, bob] = new MockProvider().getWallets();
  //let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    //lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 10000]);
    token2 = await deployContract(owner, ERC20, ["T2", 10000]);
  });

  it('Owner owns all T1 tokens', async () => {
    let totalSupplyT1 = await (token1.totalSupply());
    let ownerBalance = await (token1.balanceOf(owner.address));
    expect(totalSupplyT1).to.equal(ownerBalance);
  });

  it('Owner owns all T2 tokens', async () => {
    let totalSupplyT2 = await (token2.totalSupply());
    let ownerBalance = await (token2.balanceOf(owner.address));
    expect(totalSupplyT2).to.equal(ownerBalance)
  });

  //owner distributes 10.000 tokens t1 to Alice, and 10.000 t2 to Bob
  it('Transfer 10.000 t1 from Owner to Alice', async () =>{
      expect(await token1.transfer(alice.address, 10000)).to.be.not.reverted;
      expect(await token1.balanceOf(alice.address)).to.be.equal(10000);
      expect(await token1.balanceOf(owner.address)).to.be.equal(0);
  });

  it('Transfer 10.000 t2 from Owner to Bob', async () =>{
      expect(await token2.transfer(bob.address, 10000)).to.be.not.reverted;
      expect(await token2.balanceOf(bob.address)).to.be.equal(10000);
      expect(await token2.balanceOf(owner.address)).to.be.equal(0);
  });

  it('Transfer 10.000 t2 from Owner to Bob without allowance', async () =>{
      await expect(token2.transferFrom(owner.address, bob.address, 10000)).to.be.reverted;
      expect(await token2.balanceOf(bob.address)).to.be.equal(0);
      expect(await token2.balanceOf(owner.address)).to.be.equal(10000);
  });

  it('Transfer 10.000 t2 from Owner to Bob with allowance', async () =>{
      await token2.approve(bob.address, 10000);
      await token2.transferFrom(owner.address, bob.address, 10000);
      expect(await token2.balanceOf(bob.address)).to.be.equal(10000);
      expect(await token2.balanceOf(owner.address)).to.be.equal(0);

      //a second attempt must fail
      await expect(token2.transferFrom(owner.address, bob.address, 10000)).to.be.reverted;
  });
});



