import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool execution', () => {
  const provider = new MockProvider();
  const [owner, alice, bob, priceOracle] = provider.getWallets();
  let lp: Contract;
  let token1: Contract;

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 20000]);
    
    //the owner adds T1 reserve
    await lp.addReserve(token1.address);

    //the owner distributes tokens to Alice, Bob
    await token1.transfer(alice.address, 10000);
    await token1.transfer(bob.address, 10000);

  });


  
  it('Execution of a track of a Lending Pool', async () => {
    let lpCalledByAlice = lp.connect(alice);
    let token1CalledByAlice = token1.connect(alice);
  
    let lpCalledByBob = lp.connect(bob);
    let token1CalledByBob = token1.connect(bob);

    var aliceBalance = await token1.balanceOf(alice.address); aliceBalance=aliceBalance.toNumber();
    var bobBalance = await token1.balanceOf(bob.address); bobBalance=bobBalance.toNumber();
    var lpBalance = await token1.balanceOf(lp.address); lpBalance=lpBalance.toNumber();

    console.log("\n###########################################################\n");
    console.log('Initial state:')
    console.log('   Alice has', aliceBalance, 'tokens');
    console.log('   Bob   has', bobBalance, 'tokens');
    console.log('   LP    has', lpBalance, 'tokens\n');

    //-------------------------------------------------------------------------------------------------------------------------------------------------------------------
    //Alice and Bob deposit 5.000 T1 in the LP. Bob deposits them as collateral, Alice not.
    await token1CalledByAlice.approve(lp.address, 5000);
    await lpCalledByAlice.deposit(token1.address, 5000, false, {gasLimit: 500000});

    await token1CalledByBob.approve(lp.address, 5000);
    await lpCalledByBob.deposit(token1.address, 5000, true, {gasLimit: 500000});

    // Check balances
    expect(await token1.balanceOf(alice.address)).to.be.equal(5000);
    expect(await token1.balanceOf(bob.address)).to.be.equal(5000);
    expect(await token1.balanceOf(lp.address)).to.be.equal(10000);

    let aliceAtokens = await lp.balanceOfAtokens(alice.address, token1.address);
    let bobATokens = await lp.balanceOfAtokens(bob.address, token1.address);
    
    var aliceBalance = await token1.balanceOf(alice.address); aliceBalance=aliceBalance.toNumber();
    var bobBalance = await token1.balanceOf(bob.address); bobBalance=bobBalance.toNumber();
    var lpBalance = await token1.balanceOf(lp.address); lpBalance=lpBalance.toNumber();

    console.log("###########################################################");
    console.log('\nAlice and Bob deposit 5.000 to LP:')
    console.log('   Alice has', aliceBalance, 'tokens');
    console.log('   Bob   has', bobBalance, 'tokens');
    console.log('   LP    has', lpBalance, 'tokens\n');

    var bobMt = await lp.aTokens(bob.address, token1.address);
    console.log('Bob minted tokens:', bobMt.toNumber() );

    //-------------------------------------------------------------------------------------------------------------------------------------------------------------------
    // Bob borrows 2000 tokens
    await lpCalledByBob.borrow(token1.address, 2000, {gasLimit: 500000});

    expect(await token1.balanceOf(bob.address)).to.be.equal(7000); // 5.000 + 2.000
    expect(await token1.balanceOf(lp.address)).to.be.equal(8000); // 10.000 - 2.000 

    // Check Bob's HF after borrow
    var res = await lp.calculateUserGlobalData(bob.address);
    var bobHf = res.healthFactor/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.

    var aliceBalance = await token1.balanceOf(alice.address); aliceBalance=aliceBalance.toNumber();
    var bobBalance = await token1.balanceOf(bob.address); bobBalance=bobBalance.toNumber();
    var lpBalance = await token1.balanceOf(lp.address); lpBalance=lpBalance.toNumber();
    
    console.log("\n###########################################################");
    console.log('\nBob borrows 2.000 tokens:')
    console.log('   Alice has', aliceBalance, 'tokens');
    console.log('   Bob   has', bobBalance, 'tokens');
    console.log('   LP    has', lpBalance, 'tokens\n\n');

    var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    console.log('Bob debt is', res[1].toNumber(), 'including fee\n');
    console.log("###########################################################");


    //-------------------------------------------------------------------------------------------------------------------------------------------------------------------
    // We simulate time passes, in order to obtain an HF < 1 (under the liquidation threshold)
    console.log("\nBob borrows 2.000 tokens, his HF now is", bobHf);

    var days = 7;
    while(bobHf>1){    
        await provider.send("evm_increaseTime", [60*60*24*days]) // we add some day (in seconds)
        await provider.send("evm_mine", []) // force mine the next block


        var res = await lp.calculateUserGlobalData(bob.address);
        var bobHf = res.healthFactor/'0xDE0B6B3A7640000'; //health factor is a hex number with 10**18 precision. It is divided for (10**18)hex to obtain a decimal value.

        console.log("       After", days,"days his HF is", bobHf);
        days = days+7;
    }
    //-------------------------------------------------------------------------------------------------------------------------------------------------------------------
    console.log("\nBob can be liquidated because his HF < 1");

    var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    console.log('Bob debt is', res[1].toNumber());
    //var res = await lp.calculateUserGlobalData(bob.address);
    //console.log(res);

    //var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    //console.log(res[1].toNumber());

    var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    var bobDebtBeforeLiquidation = res[1].toNumber();

    var aliceBalanceBeforeLiq = await token1.balanceOf(alice.address);
    var aliceBalanceBeforeLiq = aliceBalanceBeforeLiq.toNumber();

    console.log('\nBefore liquidation, Alice - the liquidator - has', aliceBalanceBeforeLiq, 'tokens');

    // Alice liquidates Bob, by repaying a part of his debt 
    await token1CalledByAlice.approve(lp.address, 2005); //2005 = 2000 + 5 because Alice must repay also the Bob's fee (2000 + 0.0025%)
    await lpCalledByAlice.liquidation(token1.address, token1.address, bob.address, 2000, {gasLimit: 500000});

    var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    var bobDebtAfterLiquidation = res[1].toNumber();
    var amountLiquidated = bobDebtBeforeLiquidation-bobDebtAfterLiquidation;

    var aliceBalanceAfterLiq = await token1.balanceOf(alice.address);
    var bonusObtainedByAlice = aliceBalanceAfterLiq - aliceBalanceBeforeLiq;

    var aliceBalanceAfterLiq = aliceBalanceAfterLiq.toNumber();

    console.log('After liquidation, Alice - the liquidator - has', aliceBalanceAfterLiq, 'tokens');
    console.log('\nAlice liquidates Bob of an amount equals to', amountLiquidated, 'and obtaining a bonus of', bonusObtainedByAlice, 'tokens');

    var aliceBalance = await token1.balanceOf(alice.address); aliceBalance=aliceBalance.toNumber();
    var bobBalance = await token1.balanceOf(bob.address); bobBalance=bobBalance.toNumber();
    var lpBalance = await token1.balanceOf(lp.address); lpBalance=lpBalance.toNumber();
    console.log('\n\nAlice liquidates Bob:')
    console.log('   Alice has', aliceBalance, 'tokens');
    console.log('   Bob   has', bobBalance, 'tokens');
    console.log('   LP    has', lpBalance, 'tokens\n');

    var bobMt = await lp.aTokens(bob.address, token1.address);
    console.log('Bob minted tokens:', bobMt.toNumber() );

    var res = await lp.getUserBorrowBalances(token1.address, bob.address);
    console.log('Bob debt is', res[1].toNumber());
    console.log("\n###########################################################\n");

    //-------------------------------------------------------------------------------------------------------------------------------------------------------------------
    // Alice redeems all her tokens 
    await lpCalledByAlice.redeemAllTokens(token1.address, {gasLimit: 500000});

    var aliceBalance = await token1.balanceOf(alice.address); aliceBalance=aliceBalance.toNumber();
    var bobBalance = await token1.balanceOf(bob.address); bobBalance=bobBalance.toNumber();
    var lpBalance = await token1.balanceOf(lp.address); lpBalance=lpBalance.toNumber();

    console.log('Alice redeems all his tokens:')
    console.log('   Alice has', aliceBalance, 'tokens');
    console.log('   Bob   has', bobBalance, 'tokens');
    console.log('   LP    has', lpBalance, 'tokens\n');

    var aliceMt = await lp.aTokens(alice.address, token1.address);
    console.log('Alice minted tokens:', aliceMt.toNumber() );
    console.log("\n###########################################################\n");
 
  });

});