import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';

import LendingPool from '../build/LendingPool.json';
import ERC20       from '../build/ERC20.json';

use(solidity);

describe('Tests Lending Pool add reserves and set tokens prices', () => {
  const [owner, priceOracle, alice] = new MockProvider().getWallets();
  let lp: Contract;
  let token1: Contract;
  let token2: Contract;
  

  beforeEach(async () => {
    lp     = await deployContract(owner, LendingPool, [priceOracle.address]);
    token1 = await deployContract(owner, ERC20, ["T1", 10000]);
    token2 = await deployContract(owner, ERC20, ["T2", 10000]);
  });

  it('Owner adds 2 reserves', async () => {
    await lp.addReserve(token1.address);
    await lp.addReserve(token2.address);

    //check if the number of reserves is 2
    expect(await lp.getNumberOfReserves()).to.be.equal(2);
  });

  it('Owner can not add twice the same reserve', async () => {
    await lp.addReserve(token1.address);
    await expect(lp.addReserve(token1.address)).to.be.reverted;

    expect(await lp.getNumberOfReserves()).to.be.equal(1);
  });

  it('Oracle can modify tokens prices', async () => {
    await lp.addReserve(token1.address);

    //check if price is 1 as default
    const res1 = await (lp.reserves(token1.address));
    const defPrice = res1.price.toNumber();
    expect(defPrice).to.equal(1);

    //priceOracle try to modify prices
    const lpFromPriceOracle = lp.connect(priceOracle);
    expect( await lpFromPriceOracle.setPrice(token1.address, 2)).to.be.not.reverted;

    //check if price is correctly updated
    const res2 = await (lp.reserves(token1.address));
    const newPrice = res2.price.toNumber();
    expect(newPrice).to.equal(2);

  });


  it('Other addresses can not modify tokens prices', async () => {
    await lp.addReserve(token1.address);

    //check if price is 1 as default
    const res1 = await (lp.reserves(token1.address));
    const defPrice = res1.price.toNumber();
    expect(defPrice).to.equal(1);

    //alice try to modify prices
    const lpFromAlice = lp.connect(alice);
    await expect(lpFromAlice.setPrice(token1.address, 2)).to.be.reverted;

    //check if price is not changed
    const res2 = await (lp.reserves(token1.address));
    const newPrice = res2.price.toNumber();
    expect(newPrice).to.equal(1);

  });


});



