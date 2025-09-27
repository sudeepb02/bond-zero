// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PrincipalToken is ERC20 {
    address public issuer;

    constructor() ERC20("PrincipalToken", "PT") {
        issuer = msg.sender;
    }

    modifier onlyIssuer() {
        require(msg.sender == issuer, "!issuer");
        _;
    }

    function mint(address to, uint256 amt) external onlyIssuer {
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external onlyIssuer {
        _burn(from, amt);
    }
}
