import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

// This test demostrates that a repay action increases the HF, while the liquidation not.
describe('Tests Lending Pool repay and liquidation', () => {
  const [owner, alice, bob, priceOracle] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 10000]);
    token2 = await deployContract(owner, ERC20, ["T2", 20000]);

    //the owner adds T1 and T2 reserves
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);

    //the owner distributes tokens to Alice, Bob and LP
    await token1.transfer(alice.address, 10000);
    await token2.transfer(bob.address, 10000);
    await token2.transfer(lp.address, 10000);

  });


  
  it('Bob repays a part of Alice\'s debt', async () => {
    let lpCalledByAlice = lp.connect(alice); 
    let token1CalledByAlice = token1.connect(alice);

    let lpCalledByBob = lp.connect(bob); 
    let token2CalledByBob = token2.connect(bob);


    //Alice approve LP and deposits 10.000 T1 as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, true, {gasLimit: 500000});

    //Alice borrows 5000 T2
    await lpCalledByAlice.borrow(token2.address, 5000, {gasLimit: 500000});

    //We simulate price fluctuation of T2 in order to make Alice under liquidation
    let lpCalledByPriceOracle = lp.connect(priceOracle);
    await lpCalledByPriceOracle.setPrice(token2.address, 2);

    //Now Alice is under liquidation
    let res = await lp.calculateUserGlobalData(alice.address);

    let aliceHFunderLiq = res.healthFactor;
    aliceHFunderLiq = aliceHFunderLiq/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.
    console.log("Alice HF is ", aliceHFunderLiq, ", she is eligible for liquidation");


    //Bob approves LP to transfer 500 T2 for repay Alice
    await token2CalledByBob.approve(lp.address, 500);
    
    //Bob tries to repay a part (500) of Alice's debt
    await lpCalledByBob.repay(token2.address, 500, alice.address, {gasLimit: 500000});

    let res2 = await lp.calculateUserGlobalData(alice.address);

    let aliceHFafterRepay = res2.healthFactor;
    aliceHFafterRepay = aliceHFafterRepay/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.
    console.log("Alice HF is ", aliceHFafterRepay, ", after repay action performed by Bob for an amount of 1.000 tokens");
  });

  
  it('Bob tries to repay a borrow position of Alice, but she is in liquidation: the transaction must fail', async () => {
    let lpCalledByAlice = lp.connect(alice); 
    let token1CalledByAlice = token1.connect(alice);

    let lpCalledByBob = lp.connect(bob); 
    let token2CalledByBob = token2.connect(bob);


    //Alice approve LP and deposits 10.000 T1 as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, true, {gasLimit: 500000});

    //Alice borrows 5000 T2
    await lpCalledByAlice.borrow(token2.address, 5000, {gasLimit: 500000});

    //We simulate price fluctuation of T2 in order to make Alice under liquidation
    let lpCalledByPriceOracle = lp.connect(priceOracle);
    await lpCalledByPriceOracle.setPrice(token2.address, 2);

    //Now Alice is under liquidation
    let res = await lp.calculateUserGlobalData(alice.address);

    let aliceHFunderLiq = res.healthFactor;
    aliceHFunderLiq = aliceHFunderLiq/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.
    console.log("Alice HF is ", aliceHFunderLiq, ", she is eligible for liquidation");


    //Bob approves LP to transfer 500 T2 for repay Alice
    await token2CalledByBob.approve(lp.address, 1000);
    
    //Bob tries to repay a part (500) of Alice's debt
    await lpCalledByBob.liquidation(token1.address, token2.address, alice.address, 500, {gasLimit: 500000});

    let res2 = await lp.calculateUserGlobalData(alice.address);

    let aliceHFafterRepay = res2.healthFactor;
    aliceHFafterRepay = aliceHFafterRepay/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.
    console.log("Alice HF is ", aliceHFafterRepay, ", after liquidation action performed by Bob for an amount of 1.000 tokens");
});
