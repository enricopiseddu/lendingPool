import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool borrow function', async() => {
  const [owner, alice, bob, priceOracle] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 10000]);
    token2 = await deployContract(owner, ERC20, ["T2", 10000]);

    //the owner adds T1 and T2 reserves
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);

    //the owner distributes tokens to alice and bob
    await token1.transfer(alice.address, 10000);
    await token2.transfer(bob.address, 10000);

    //Bob approves and deposits all his T2 tokens in LP not as collateral
    const token2calledByBob = token2.connect(bob);
    await token2calledByBob.approve(lp.address, 10000);

    const lpCalledByBob = lp.connect(bob);
    await lpCalledByBob.deposit(token2.address, 10000, false);
    
    // From now, Alice will try to borrow some T2 tokens
  });


  
  it('Alice tries to borrow 6.000 T2 using 5.000 T1 as collateral: transaction failed', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    const tokenT1calledByAlice = token1.connect(alice);

    //Alice must approve the LP to deposit 5.000 t1
    await tokenT1calledByAlice.approve(lp.address, 5000);

    //Alice deposits 5.000 t1 to LP as collateral
    await lpCalledByAlice.deposit(tokenT1calledByAlice.address, 5000, true);

    //Check balances of T1 of alice and Lending Pool
    expect(await token1.balanceOf(alice.address)).to.be.equal(5000);
    expect(await token1.balanceOf(lp.address)).to.be.equal(5000);

    await expect(lpCalledByAlice.borrow(token2.address, 6000)).to.be.revertedWith('There is not enough collateral to cover a new borrow');
  });


   it('Bob tries to borrow 1.000 T1 but reserve T1 is empty: transaction failed', async () => {
    const lpCalledByBob = lp.connect(bob);

    expect(await token1.balanceOf(lp.address)).to.be.equal(0);

    await expect(lpCalledByBob.borrow(token1.address, 1000)).to.be.revertedWith('Not enough liquidity for the borrow');
  
   });
  
    it('Alice tries to borrow 1.000 T2 using 5.000 T1 as collateral', async () => { 
    const tokenT1calledByAlice = token1.connect(alice);

    //Alice must approve the LP to deposit 5.000 t1
    await tokenT1calledByAlice.approve(lp.address, 5000);

    const lpCalledByAlice = lp.connect(alice);

    //Alice deposits 5.000 t1 to LP as collateral
    await lpCalledByAlice.deposit(token1.address, 5000, true);

    //Check balances of T1 of alice and Lending Pool
    expect(await token1.balanceOf(alice.address)).to.be.equal(5000);
    expect(await token1.balanceOf(lp.address)).to.be.equal(5000);
    expect(await token2.balanceOf(lp.address)).to.be.equal(10000);
    
    await expect(lpCalledByAlice.borrow(token2.address, 1000)).to.be.not.reverted;

    //Check new balances of T2 of alice and LP
    expect(await token2.balanceOf(alice.address)).to.be.equal(1000);
    expect(await token2.balanceOf(lp.address)).to.be.equal(9000);
  });



});
