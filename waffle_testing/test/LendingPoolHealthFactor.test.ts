import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests health factor (HF) before and after borrowing', async() => {
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

    //Bob approves and deposits all his T2 tokens to LP not as collateral
    const tokenT2calledByBob = token2.connect(bob);
    await tokenT2calledByBob.approve(lp.address, 10000);

    const lpCalledByBob = lp.connect(bob);
    await lpCalledByBob.deposit(token2.address, 10000, false);

    //Alice approves and deposits all her T1 tokens in LP as collateral
    const tokenT1calledByAlice = token1.connect(alice);
    await tokenT1calledByAlice.approve(lp.address, 10000);

    const lpCalledByAlice = lp.connect(alice);
    await lpCalledByAlice.deposit(token1.address, 10000, true);
    
  });


  
  it('Alice has no borrow, so his HF must be set to maximum', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    
    const res = await lp.calculateUserGlobalData(alice.address);

    const aliceHF = res.healthFactor;

    //check ih Alice's HF is set to maximum (2**256 -1)
    const maxHF = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
    expect(maxHF).to.equal(aliceHF);
    });


    
   it('Alice deposits 10.000T1 as collateral, then borrows 1.000 T2: her HF must decrease ', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    
    await lpCalledByAlice.borrow(token2.address, 1000);

    const res = await lp.calculateUserGlobalData(alice.address);

    const aliceHFafterBorrow = res.healthFactor;
    const maxHF = '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

    //check ih Alice's HF is lower than maximum (2**256 -1)
    expect(aliceHFafterBorrow).to.be.lt(maxHF);
    });


    
    it('Simulation of price fluctuation that brings Alice\'s HF < 1', async () => {
    const lpCalledByAlice = lp.connect(alice); //using this variable, transactions on Lending Pool are sent by Alice
    
    await lpCalledByAlice.borrow(token2.address, 1000);
    
    const lpCalledByPriceOracle = lp.connect(priceOracle);
    await lpCalledByPriceOracle.setPrice(token2.address, 20); //the price of T2 increases (alice borrowed T1)

    
    const res = await lp.calculateUserGlobalData(alice.address);
    const aliceHFafterPriceIncreased = res.healthFactor;


    //check ih Alice's HF is lower than maximum 1
    const HFliquidationThreshold = '0xde0b6b3a7640000';
    expect(aliceHFafterPriceIncreased).to.be.lt(HFliquidationThreshold);
    });

});