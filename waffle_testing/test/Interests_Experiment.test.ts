import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Simulation of the time and interests', () => {
  const provider = new MockProvider();
  const [owner, alice, bob, priceOracle] = provider.getWallets();

  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  let token3: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 100000]);
    token2 = await deployContract(owner, ERC20, ["T2", 100000]);
    token3 = await deployContract(owner, ERC20, ['T3', 500000]);

    //the owner adds T1, T2 and T3 reserves
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);
    await lp.addReserve(token3.address);

    //the owner distributes tokens to LP, alice and bob
    await token1.transfer(lp.address, 100000);
    await token2.transfer(lp.address, 100000);

    await token3.transfer(alice.address, 250000);
    await token3.transfer(bob.address, 250000);

    //Bob deposits 250.000 T3 as collateral
    let token3CalledByBob = token3.connect(bob);
    await token3CalledByBob.approve(lp.address, 250000);

    let lpCalledByBob = lp.connect(bob);
    await lpCalledByBob.deposit(token3.address, 250000, true, {gasLimit: 500000});

    
    let amountBorrowedByBob = 70000 // This variable is used in order to simulate the utilization rate of T1 reserve 
    await lpCalledByBob.borrow(token1.address, amountBorrowedByBob, {gasLimit: 500000})

  });


  it('Alice borrows 10.000 T1 (reserve underused)', async () => {
      
      //Alice deposits 20.000 T3 as collateral
      let token3CalledByAlice = token3.connect(alice);
      await token3CalledByAlice.approve(lp.address, 20000);

      let lpCalledByAlice = lp.connect(alice);
      await lpCalledByAlice.deposit(token3.address, 20000, true, {gasLimit: 500000});

      //Alice borrows 10.000 T1
      await lpCalledByAlice.borrow(token1.address, 10000, {gasLimit: 500000});

      var res = await lpCalledByAlice.getUserBorrowBalances(token1.address, alice.address);
      
      console.log(res[1].toNumber());

      // We simulate time passes (10 days) in order to see how interests increase
      for(let i=0; i<10; i++){

          await provider.send("evm_increaseTime", [60*60*24]); // we add 1 day (in seconds)
          await provider.send("evm_mine", []); // force mine the next block

          res = await lpCalledByAlice.getUserBorrowBalances(token1.address, alice.address);
          
          console.log(res[1].toNumber());
      }

  });
});