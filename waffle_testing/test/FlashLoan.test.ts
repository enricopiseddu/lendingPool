import {expect, use} from 'chai';
import {Contract} from 'ethers';
import {deployContract, MockProvider, solidity} from 'ethereum-waffle';


import FlashLoan     from '../build/FlashLoan.json';
import GoodReceiver  from '../build/GoodReceiver.json';
import BadReceiver   from '../build/BadReceiver.json';
import ERC20         from '../build/ERC20.json';

use(solidity);

describe('Tests Flash Loan contract', () => {
  const [owner] = new MockProvider().getWallets();
  let flashLoanContract: Contract;
  let token: Contract;
  let goodReceiver: Contract;
  let badReceiver: Contract;
  

  beforeEach(async () => {
    //initialization 
    flashLoanContract = await deployContract(owner, FlashLoan);
    token  = await deployContract(owner, ERC20, ["TokenSymbol", 150000]);
    goodReceiver = await deployContract(owner, GoodReceiver);
    badReceiver = await deployContract(owner, BadReceiver);

    //The owner transfers 50.000 tokens to flashLoanContract, 50.000 to goodReceiverContract and badReceiverContract
    await token.transfer(flashLoanContract.address, 50000);
    await token.transfer(goodReceiver.address, 50000);
    await token.transfer(badReceiver.address, 50000);

    await goodReceiver.setflashLoanContractAddress(flashLoanContract.address);

  });


  
  it('Flash loan is performed by repaying all the amount + fee', async () => {
    
    // Perform a flashLoan of 10.000 tokens. The goodReceiverContract should obtain the loan
    let amountToBorrow = 10000;
    await expect(flashLoanContract.flashLoan(goodReceiver.address, token.address, amountToBorrow)).to.be.not.reverted;

    let fee = amountToBorrow*5/100; //Compute the fee, that is 5%
    
    let balanceOfFlashLoanContractAfterLoan = 50000 + fee;
    let balanceOfGoodReceiverContractAfterLoan = 50000 - fee;
    
    // Check if the flashLoan contract obtains the amount borrowed + fee
    expect(await token.balanceOf(flashLoanContract.address)).to.be.equal(balanceOfFlashLoanContractAfterLoan);
    // Check if goodReceiver contract pays the debt + fee
    expect(await token.balanceOf(goodReceiver.address)).to.be.equal(balanceOfGoodReceiverContractAfterLoan);
  });


  it('Flash loan must revert because the receiver contract does not repay the fee', async () => {
    
    // PTry to perform a flashLoan of 10.000 tokens. The badReceiverContract should not obtain the loan
    let amountToBorrow = 10000;
    await expect(flashLoanContract.flashLoan(badReceiver.address, token.address, amountToBorrow)).to.be.reverted;
    
    let balanceOfFlashLoanContractAfterLoan = 50000;
    let balanceOfBadReceiverContractAfterLoan = 50000;

    // Since the flashLoan should revert, check if balance are not changed
    expect(await token.balanceOf(flashLoanContract.address)).to.be.equal(balanceOfFlashLoanContractAfterLoan);
    expect(await token.balanceOf(goodReceiver.address)).to.be.equal(balanceOfBadReceiverContractAfterLoan);
  });
  

});