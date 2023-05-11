import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests on Users setting or not reserve as collateral', () => {
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
    await token1.transfer(bob.address, 10000);
    await token2.transfer(alice.address, 10000);

    //Bob deposits 10.000 T1 not as collateral
    let token1CalledByBob = token1.connect(bob);
    await token1CalledByBob.approve(lp.address, 10000);

    let lpCalledByBob = lp.connect(bob);
    await lpCalledByBob.deposit(token1.address, 10000, false, {gasLimit: 500000});

  });


  it('Since Bob has no borrow, he can decide to not use T1 as collateral ', async () => {
      let lpCalledByBob = lp.connect(bob);

      //Bob can set T1 reserve as collateral
      await expect(lpCalledByBob.setuserUseReserveAsCollateral(token1.address, true)).to.be.not.reverted;
  });


  it('Since Alice is using T2 as collateral for a T1 borrow, she can not decide to not use it more as collateral', async () => {
     //Alice deposits 10.000 T2 as collateral, then she borrows 1.000 T1
    let token2CalledByAlice = token2.connect(alice);
    await token2CalledByAlice.approve(lp.address, 10000);

    let lpCalledByAlice = lp.connect(alice);
    await lpCalledByAlice.deposit(token2.address, 10000, true, {gasLimit: 500000});

    await lpCalledByAlice.borrow(token1.address, 1000, {gasLimit: 500000});

    //ALice tries to set T2 reserve not as her collateral
    await expect(lpCalledByAlice.setuserUseReserveAsCollateral(token2.address, false)).to.be.reverted;

  });

});