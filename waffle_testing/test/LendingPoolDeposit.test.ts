import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool deposit function', () => {
  const [owner, alice, priceOracle] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 10000]);
    await lp.addReserve(token1.address);

    //the owner of T1 transfer to Alice 10.000
    await token1.transfer(alice.address, 10000);
    
  });


  
  it('Alice approves and deposits 10.000 token T1 on LP', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    const tokenT1calledByAlice = token1.connect(alice);

    //Alice must approve the LP to deposit 10.000t1
    await tokenT1calledByAlice.approve(lp.address, 10000);

    //Alice deposits 10.000 t1 to LP as collateral
    await lpCalledByAlice.deposit(token1.address, 10000, true);

    expect(await token1.balanceOf(alice.address)).to.be.equal(0);
    expect(await token1.balanceOf(lp.address)).to.be.equal(10000);
  });

  it('Alice does not approves and deposits action of 10.000 token T1 on LP fails', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    const tokenT1calledByAlice = token1.connect(alice);

    //Alice does not approve the LP to deposit 10.000t1
    //await tokenT1calledByAlice.approve(lp.address, 10000);

    //Alice tries deposits 10.000 t1 to LP as collateral
    await expect(lpCalledByAlice.deposit(token1.address, 10000, true)).to.be.reverted;

    expect(await token1.balanceOf(alice.address)).to.be.equal(10000);
    expect(await token1.balanceOf(lp.address)).to.be.equal(0);
  });


  it('Alice deposits more tokens than she has approved to: transaction must fail ', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    const tokenT1calledByAlice = token1.connect(alice);

    //Alice approves the LP to deposit 5.000 t1
    await tokenT1calledByAlice.approve(lp.address, 5000);

    //Alice tries deposits 6000 t1 to LP as collateral: this tx must fail
    await expect(lpCalledByAlice.deposit(token1.address, 6000, true)).to.be.reverted;

    expect(await token1.balanceOf(alice.address)).to.be.equal(10000);
    expect(await token1.balanceOf(lp.address)).to.be.equal(0);
  });
});
