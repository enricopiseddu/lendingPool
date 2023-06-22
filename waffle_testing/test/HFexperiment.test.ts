import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);


//Before launch the simulation, we can set the Liquidation Bonus in the Lending Pool library.
describe('Simulation of Lending Pool liquidation rounds', () => {
  const [owner, alice, bob, priceOracle] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    //initialization 
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 50000]);
    token2 = await deployContract(owner, ERC20, ["T2", 10000]);

    //the owner adds T1 and T2 reserves
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);

    //the owner distributes tokens to Bob, Alice and LP
    await token1.transfer(bob.address, 25000);
    await token2.transfer(alice.address, 10000);
    await token1.transfer(lp.address, 25000);

  });
  

  
  it('Simulation of Lending Pool liquidation rounds', async () => {
    let lpCalledByBob = lp.connect(bob);
    let token1CalledByBob = token1.connect(bob);
    
    let lpCalledByAlice = lp.connect(alice);
    let token2CalledByAlice = token2.connect(alice);

    //Alice uses 10.000 T2 as collateral, then she borrows 5.000 T1
    await token2CalledByAlice.approve(lp.address, 10000);
    await lpCalledByAlice.deposit(token2.address, 10000, true, {gasLimit: 500000});
    await lpCalledByAlice.borrow(token1.address, 5000, {gasLimit: 500000});

    //We simulate price fluctuation of token borrowed in order to make Alice's HF under the threshold
    let lpCalledByOracle = lp.connect(priceOracle);
    await lpCalledByOracle.setPrice(token1.address, 2); // now, 1 token t1 = 2 ETH

    let res = await lp.calculateUserGlobalData(alice.address);//HF (=res) is expressed in hex with 10**18 digits
    let aliceHF = res.healthFactor/'0xDE0B6B3A7640000';//we obtain HF in decimal by dividing res for (10**18)hex


    // We see how Alice's HF decreases due to liquidation rounds
    for(let i=0; i<9; i++){
        // Bob liquidates alice
        await token1CalledByBob.approve(lp.address, 700);
        await lpCalledByBob.liquidation(token2.address, token1.address, alice.address, 500,{gasLimit: 500000});

        res = await lp.calculateUserGlobalData(alice.address); 
        aliceHF = res.healthFactor/'0xDE0B6B3A7640000'; 
        console.log(aliceHF);
    }
  });
});