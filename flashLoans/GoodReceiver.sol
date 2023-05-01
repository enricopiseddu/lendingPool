// SPDX-License-Identifier: CC-BY-4.0

pragma solidity >=0.7.0 <0.9.0;

import "IFlashLoanReceiver.sol";
import "ERC20.sol";
import "Ownable.sol";

contract GoodReceiver is IFlashLoanReceiver, Ownable{

    address public flashLoanContract;

    function executeOperation(address _reserve, uint256 _amount, uint256 _fee) override public{
        ERC20 reserve = ERC20(_reserve);

        //Compute the amount to be returned, including the fee
        uint256 amountToReturnToLP = _amount + _fee;

        //Approve and transfer the amount to be returned
        reserve.approve(flashLoanContract, amountToReturnToLP);
        reserve.transferFrom(address(this), flashLoanContract, amountToReturnToLP);
    }

    //This function sets the address of the contract that provides the flash loan
    function setflashLoanContractAddress(address _address) public onlyOwner{
        flashLoanContract = _address;
    }

}