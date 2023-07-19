pragma solidity 0.8.18;

interface IERC1363 {
    function transferAndCall(address recipient, uint256 amount) external returns (bool);
}

interface IERC1363Receiver {
    function onTransferReceived(address sender, uint256 amount, bytes calldata data) external returns (bytes4);
}

contract TokenBondingCurve is IERC1363, IERC1363Receiver {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    uint256 public constant INITIAL_PRICE = 1000; // Initial price of tokens
    uint256 public constant INITIAL_SUPPLY = 1000000; // Initial token supply

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = INITIAL_SUPPLY;
    }

    receive() external payable {
        buyTokens(msg.value);
    }

    function transferAndCall(address recipient, uint256 amount) external override returns (bool) {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid token amount");

        // Calculate the Ether amount to return to the seller
        uint256 ethAmount = calculateEtherToReturn(amount);

        // Burn tokens from the seller
        totalSupply -= amount;

        // Transfer Ether back to the seller
        payable(msg.sender).transfer(ethAmount);

        return true;
    }

    function onTransferReceived(
        address sender,
        uint256 amount,
        bytes calldata data
    ) external override returns (bytes4) {
        require(sender != address(0), "Invalid sender");
        require(amount > 0, "Invalid token amount");

        // Calculate the Ether amount to return to the seller
        uint256 ethAmount = calculateEtherToReturn(amount);

        // Burn tokens from the seller
        totalSupply -= amount;

        // Transfer Ether back to the seller
        payable(sender).transfer(ethAmount);

        return this.onTransferReceived.selector;
    }

    function buyTokens(uint256 ethAmount) internal {
        require(ethAmount > 0, "Invalid Ether amount");

        uint256 tokenAmount = calculateTokensToMint(ethAmount);

        // Mint tokens to the buyer
        totalSupply += tokenAmount;
        IERC1363(msg.sender).transferAndCall(msg.sender, tokenAmount);
    }

    function calculateTokensToMint(uint256 ethAmount) internal view returns (uint256) {
        return (ethAmount * totalSupply) / INITIAL_SUPPLY / INITIAL_PRICE;
    }

    function calculateEtherToReturn(uint256 tokenAmount) internal view returns (uint256) {
        return (tokenAmount * INITIAL_SUPPLY * INITIAL_PRICE) / totalSupply;
    }
}

// In this example, the TokenBondingCurve contract implements the ERC1363 token standard and the ERC1363Receiver interface. The contract includes the purchase and minting functionality based on a linear bonding curve, as well as the selling and burning of tokens with the corresponding return of Ether to the seller.

// The buyTokens function is triggered when a user sends Ether to the contract's receive function. It calculates the amount of tokens to mint based on the Ether amount using the calculateTokensToMint function. The contract mints the tokens to the buyer using the transferAndCall function from the ERC1363 token contract.

// The onTransferReceived function is triggered when a user sends tokens back to the contract. It receives the sender's address, token amount, and data. The contract calculates the corresponding Ether amount to return using the calculateEtherToReturn function. The tokens are burned, and the Ether amount is transferred back to the seller using the transfer function.

// Please note that the contract assumes the existence of an ERC1363 token contract that implements the transferAndCall function to handle the token transfers.
