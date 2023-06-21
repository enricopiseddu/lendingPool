import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool repay function', () => {
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


  
  it('Bob tries to repay the debt of Alice, but Alice has no debts: transaction must fail', async () => {
    let lpCalledByBob = lp.connect(bob);
    let token2CalledByBob = token1.connect(bob);

    //Bon approves LP to transfer 10.000 T2 for repay Alice
    await token2CalledByBob.approve(lp.address, 10000);

    await expect(lpCalledByBob.repay(token2.address, 10000, alice.address, {gasLimit: 500000})).to.be.reverted;

    expect(await token2.balanceOf(bob.address)).to.be.equal(10000);
  });

  
  it('Bob can completely repay the debt of Alice (she is not in liquidation)', async () => {
    let lpCalledByAlice = lp.connect(alice); 
    let token1CalledByAlice = token1.connect(alice);

    let lpCalledByBob = lp.connect(bob); 
    let token2CalledByBob = token2.connect(bob);


    //Alice approve LP and deposits 10.000 T1 as collateral
    await token1CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token1.address, 10000, true, {gasLimit: 500000});

    //Alice borrows 5000 T2
    await lpCalledByAlice.borrow(token2.address, 5000, {gasLimit: 500000});   

    let res = await lp.getUserBorrowBalances(token2.address, alice.address);

    let {0: value1, 1: amountToRepay, 2: value3} = res; //amountToRepay is the amount borrowed + fee + interests
    amountToRepay = amountToRepay.toNumber();

    //Bob approves LP to transfer the amountToRepay T2 for repay Alice
    await token2CalledByBob.approve(lp.address, amountToRepay);

    //Bob repays the Alice's debt
    await expect(lpCalledByBob.repay(token2.address, amountToRepay, alice.address, {gasLimit: 500000})).to.be.not.reverted;

    let resAfterRepay = await lpCalledByBob.getUserBorrowBalances(token2.address, alice.address);
    let {0: value1notused, 1: debtOfAlice, 2: value3notused} = resAfterRepay;

    debtOfAlice = debtOfAlice.toNumber();
    let newBobBalance = 10000 - amountToRepay;

    expect(debtOfAlice).to.be.equal(0);
    expect(await token2.balanceOf(bob.address)).to.be.equal(newBobBalance);

   });

});
