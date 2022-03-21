//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract ETHTestToken is ERC20 {
    constructor(uint256 initialSupply) public ERC20("ETHTest", "ETH") {
        _mint(msg.sender, initialSupply);
    }

    function mint(address add , uint256 suply) public {
        _mint(add,suply);
    }
}
