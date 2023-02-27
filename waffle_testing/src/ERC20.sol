// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "./IERC20.sol";

/**
 * @title Standard ERC20 token
 *
 * @dev Implementation of the basic standard token.
 * https://eips.ethereum.org/EIPS/eip-20
 *
 * Eliminate tutte le funzioni eccetto quelle dello standard originale ERC20
 * 
 */
contract ERC20 is IERC20 {

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint256 private _totalSupply;    
    string  private _symbol;

    constructor (string memory symbol_, uint totalSupply_) {
        _totalSupply = totalSupply_;
        _balances[msg.sender] = totalSupply_;
        _symbol = symbol_;
    }
  function symbol() public view returns(string memory) {
    return _symbol;
}

/**
 * @dev Total number of tokens in existence.
 */
function totalSupply() override public view returns (uint256) {
        return _totalSupply;
}

/**
 * @dev Gets the balance of the specified address.
 * @param _account The address to query the balance of.
 * @return A uint256 representing the amount owned by the passed address.
 */
function balanceOf(address _account) override public view returns (uint256) {
    return _balances[_account];
}

/**
 * @dev Function to check the amount of tokens that an owner allowed to a spender.
 * @param _owner address The address which owns the funds.
 * @param _spender address The address which will spend the funds.
 * @return A uint256 specifying the amount of tokens still available for the spender.
 */
function allowance(address _owner, address _spender) override public view returns (uint256) {
    return _allowances[_owner][_spender];
}  
/**
     * @dev Transfer token to a specified address.
     * @param _to The address to transfer to.
     * @param _amount The amount to be transferred.
     */
    function transfer(address _to, uint256 _amount) override public returns (bool) {
        _transfer(msg.sender, _to, _amount);
        return true;
    }
    /**
     * @dev Approve the passed address to spend the specified amount of tokens on behalf of
     * msg.sender.
     * Beware that changing an allowance with this method brings the risk that someone may 
     * use both the old and the new allowance by unfortunate transaction ordering. 
     * One possible solution to mitigate this race condition is to first reduce the spender's
     * allowance to 0 and set the desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     */
    function approve(address spender, uint256 value) override public returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }
    /**
     * @dev Transfer tokens from one address to another.
     * Note that while this function emits an Approval event, this is not required as per 
     * the specification, and other compliant implementations may not emit the event.
     * @param _from address The address which you want to send tokens from
     * @param _to address The address which you want to transfer to
     * @param _amount uint256 the amount of tokens to be transferred
     */
    function transferFrom(address _from, address _to, uint256 _amount) override public returns (bool) {
        _transfer(_from, _to, _amount);
        uint256 _currentAllowance = _allowances[_from][_to];
        require(_currentAllowance >= _amount, "ERC20: transfer amount exceeds allowance");
        _approve(_from, _to, _currentAllowance - _amount);
        return true;
    }

    /**
     * @dev Transfer token for a specified addresses.
     * @param _from The address to transfer from.
     * @param _to The address to transfer to.
     * @param _amount The amount to be transferred.
     */
    function _transfer(address _from, address _to, uint256 _amount) internal {
        require(_from != address(0), "ERC20: transfer from the zero address");
        require(_to != address(0), "ERC20: transfer to the zero address");
        uint256 _senderBalance = _balances[_from];
        require(_senderBalance >= _amount, "ERC20: transfer amount exceeds balance");
        _balances[_from] = _senderBalance - _amount;
        _balances[_to] += _amount;
        emit Transfer(_from, _to, _amount);
    }

    /**
     * @dev Approve an address to spend another addresses' tokens.
     * @param _owner The address that owns the tokens.
     * @param _spender The address that will spend the tokens.
     * @param _amount The number of tokens that can be spent.
     */
    function _approve(address _owner, address _spender, uint256 _amount) internal {
        require(_owner != address(0), "ERC20: approve from the zero address");
        require(_spender != address(0), "ERC20: approve to the zero address");

        _allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }
}
