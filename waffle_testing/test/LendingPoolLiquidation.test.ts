import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool liquidation function', () => {
  const [owner, alice, bob, priceOracle] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 20000]);
    token2 = await deployContract(owner, ERC20, ["T2", 10000]);

    //the owner adds T1 and T2 reserves
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);

    //the owner distributes tokens to Bob, Alice and LP
    await token1.transfer(bob.address, 10000);
    await token2.transfer(alice.address, 10000);
    await token1.transfer(lp.address, 10000);

  });


  
  it('Bob tries to liquidate Alice, but she has not borrows: the transaction must fail', async () => {
    let lpCalledByBob = lp.connect(bob);
    let token1CalledByBob = token1.connect(bob);

    //Bob approves LP to take 1000T1
    await token1CalledByBob.approve(lp.address, 1000);

    //Bob tries to liquidate Alice, but she has no borrows
    await expect(lpCalledByBob.liquidation(token2.address, token1.address, alice.address, 1000)).to.be.reverted;

    expect(await token1.balanceOf(bob.address)).to.be.equal(10000);
  });


  it('Bob tries to liquidate Alice, but she has enough collateral to cover her borrow: the transaction must fail', async () => {
    let lpCalledByBob = lp.connect(bob);
    let token1CalledByBob = token1.connect(bob);

    let lpCalledByAlice = lp.connect(alice);
    let token2CalledByAlice = token2.connect(alice);

    //Alice uses 10.000 T2 as collateral, then she borrows 1.000 T1
    await token2CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token2.address, 10000, true);
    await lpCalledByAlice.borrow(token1.address, 1000);

    //check if Alice's HF is above the treshold
    let res = await lp.calculateUserGlobalData(alice.address);
    let aliceHF = res.healthFactor;
    let threshold = '0xde0b6B3a7640000'; //1e18 === 1 (see WadRayMath library)
    expect(aliceHF).to.gt(threshold); 

    //Bob approves LP to take 1000T1
    await token1CalledByBob.approve(lp.address, 1000);

    //Bob tries to liquidate alice: the tx must fail
    await expect(lpCalledByBob.liquidation(token2.address, token1.address, alice.address, 1000)).to.be.reverted;
  });


  it('Bob can liquidate Alice, because her HF is under the threshold', async () => {
    let lpCalledByAlice = lp.connect(alice); 
    let lpCalledByBob = lp.connect(bob);

    let token2CalledByAlice = token2.connect(alice);
    let token1CalledByBob = token1.connect(bob);

    let bobBalanceT1beforeLiquidation = await token1.balanceOf(bob.address);
    let bobBalanceT2beforeLiquidation = await token2.balanceOf(bob.address);

    //Alice approve LP and deposits 10.000 T2 as collateral
    await token2CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token2.address, 10000, true);

    //Alice borrows 5.000 T2
    await lpCalledByAlice.borrow(token1.address, 5000);

    //Check if alice obtains 5.000T2 tokens
    expect(await token1.balanceOf(alice.address)).to.be.equal(5000);

    //We simulate price fluctuation of token borrowed in order to make Alice's HF under the threshold
    let lpCalledByOracle = lp.connect(priceOracle);
    await lpCalledByOracle.setPrice(token1.address, 2); // now, 1 token t1 = 2 ETH

    //check if Alice's HF is UNDER the treshold => she is in liquidation
    let res = await lp.calculateUserGlobalData(alice.address);
    let aliceHFbeforeLiquidation = res.healthFactor;
    let threshold = '0xde0b6B3a7640000'; //1e18 === 1 (see WadRayMath library)
    expect(aliceHFbeforeLiquidation).to.lt(threshold);

    
    //Bob approves LP to take 5000T1
    await token1CalledByBob.approve(lp.address, 5000);

    let {0: value1, 1: debtOfAliceBeforeLiquidation, 2: value2} = await lp.getUserBorrowBalances(token1.address, alice.address);

    //Bob liquidates Alice
    await lpCalledByBob.liquidation(token2.address, token1.address, alice.address, 5000);

    let bobBalanceT1afterLiquidation = await token1.balanceOf(bob.address);
    let bobBalanceT2afterLiquidation = await token2.balanceOf(bob.address);
    
    console.log("Bob liquidates Alice by repaying " + (bobBalanceT1beforeLiquidation-bobBalanceT1afterLiquidation) + ' tokens T1 having a value of ' + (bobBalanceT1beforeLiquidation-bobBalanceT1afterLiquidation)*2, " ethers (1 tok T1 = 2 ETH)"); // 1 T1 = 2 ETH
    console.log("From the liquidation, Bob earns " + (bobBalanceT2beforeLiquidation+bobBalanceT2afterLiquidation) + " tokens T2 having a value of " + (bobBalanceT2beforeLiquidation+bobBalanceT2afterLiquidation)*1, " ethers (1 tok T2 = 1 ETH)"); // 1 T2 = 1 ETH
    console.log("The bonus obtained by Bob has a value of ", ((bobBalanceT2beforeLiquidation+bobBalanceT2afterLiquidation)*1)-((bobBalanceT1beforeLiquidation-bobBalanceT1afterLiquidation)*2) + " ethers, the same value of tokens t2 obtained (1 tok T2 = 1 ETH)");


    let {0: value3, 1: debtOfAliceAfterLiquidation, 2: value4} = await lp.getUserBorrowBalances(token1.address, alice.address); 

    console.log('Debt of Alice before liquidation is ' + debtOfAliceBeforeLiquidation + " tokens T1");
    console.log('Debt of Alice after  liquidation is ' + debtOfAliceAfterLiquidation + " tokens T1");
  });

});