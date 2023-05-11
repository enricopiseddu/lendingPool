import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool redeem function', () => {
  const [owner, alice, priceOracle] = new MockProvider().getWallets();
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

    //the owner distributes tokens to LP and to Alice
    await token1.transfer(alice.address, 10000);
    await token2.transfer(lp.address, 10000);

  });


  
  it('Alice tries to redeem aTokens of type T2, but she does not own them: the transaction must fail', async () => {
    let lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice

    await expect(lpCalledByAlice.redeemAllTokens(token2.address, {gasLimit: 300000})).to.be.reverted;

    expect(await token2.balanceOf(alice.address)).to.be.equal(0);
  });


  it('Alice tries to redeem aTokens of type T1 deposited and used as collateral for an active borrow: the transaction must fail', async () => {
    let lpCalledByAlice = lp.connect(alice); 
    let token1CalledByAlice = token1.connect(alice);

    //Alice approve LP and deposits 10.000 T1 as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, true);

    //Alice borrows 1000 T2
    await lpCalledByAlice.borrow(token2.address, 1000, {gasLimit: 300000});

    //Check if alice obtains T2 tokens
    expect(await token2.balanceOf(alice.address)).to.be.equal(1000);

    await expect(lpCalledByAlice.redeemAllTokens(token1.address, {gasLimit: 300000})).to.be.reverted;

    expect(await token1.balanceOf(alice.address)).to.be.equal(0);
  });


   it('Alice can redeem all T1 tokens deposited but not used as collateral', async () => {
    let lpCalledByAlice = lp.connect(alice);
    let token1CalledByAlice = token1.connect(alice);
    
    //Alice deposits 10.000 T1 not as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, false);

    expect(await token1.balanceOf(alice.address)).to.be.equal(0);

    //Alice redeems all his T1 tokens
    await lpCalledByAlice.redeemAllTokens(token1.address, {gasLimit: 300000});

    expect(await token1.balanceOf(alice.address)).to.be.equal(10000);
   });


   it('Alice can redeem all T1 tokens deposited as collateral because she has no active borrows', async () => {
    let lpCalledByAlice = lp.connect(alice);
    let token1CalledByAlice = token1.connect(alice);
    
    //Alice deposits 10.000 T1 as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, true);

    expect(await token1.balanceOf(alice.address)).to.be.equal(0);

    //Alice redeems all his T1 tokens
    await lpCalledByAlice.redeemAllTokens(token1.address, {gasLimit: 300000});

    expect(await token1.balanceOf(alice.address)).to.be.equal(10000);
   });


});
