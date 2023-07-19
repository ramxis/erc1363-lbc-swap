// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./MyERC1363Token.sol";

/**
 * @title A contract that allows exchnage of mithril tokens (ERC1363) for eth and vice versa.
 * @notice The exchange rate is determined by a linear bonding curve.
 *
 * @dev linear bonding curver eq: y = mx + b
 *      to keep this take home exercise simple we take slope value m = 1 and b = 0
 *      for the purposes of this excercise I am not capping the supply of the minted mithril token
 *      however it is possible to also program this contract with any slope value from 1 - n
 *      we will just have to adjust the formulas accordingly
 *
 *      to compute poolBalance for any given price use integral y = m * 1/2 * x ^ 2
 *      for the simplest case when m = 1; and b=0, poolBalance = 1/2 * x ^ 2
 *      where x is the totalsupply of mithril.
 *
 *      reserveRatio = 1/2
 */

contract LbcTokenSwaplegacy is IERC1363Receiver, ERC165, Context, ReentrancyGuard {
    //FIXME: add mechanism to mitigate front running attacks

    using SafeMath for uint256;

    using Address for address payable; // prettier-ignore

    // must be divisible by 2 & at least 14 to accurately calculate cost
    uint8 public immutable bondingCurveDecimals;

    // shorthand for decimal
    // dec = (10 ** uint256(bondingCurveDecimals));
    uint256 dec;

    // multiple is the cost of 1 * multple tokens
    // multiple will effect accuracy
    // it should be around 10 ** 8 - 10 ** 12 to limit rounding errors
    uint256 public immutable multiple;

    // ERC1363 token which is accepted
    MyERC1363Token public mithrilToken;

    // the address of the token which will be deployed and is used in the linear bonding curver
    address public immutable tokenAddress;

    /**
     * @dev it is used to keep track of contracts ether balance
     *      we do not use this.balance to account for the edge case of eth sent from selfdestruct contract
     *      if ethers are sent via selfdestruct no function is called including fallback / receive
     *      https://hackernoon.com/how-to-hack-smart-contracts-self-destruct-and-solidity
     */
    uint256 public poolBalance;

    /**
     * @dev Emitted when `amount` tokens are moved from one account (`sender`) to
     *      this by spender (`operator`) using `transferAndCall` or `transferFromAndCall`.
     */
    event TokensReceived(address indexed operator, address indexed sender, uint256 amount);

    /**
     * @notice Event emitted when new tokens are minted by the bonding curve
     *
     * @param sender - address of the sender who sent eth into the bonding curver
     * @param amountMinted -  the amount of tokens minted by the bonding curver
     * @param totalCost -  total cost to mint in wei
     */
    event LogMint(address indexed sender, uint256 amountMinted, uint256 totalCost);

    /**
     * @notice Event emitted when new tokens are minted by the bonding curve
     *
     * @param sender - address of the sender who sent tokens to burn
     * @param amountBurnt -  the amount of tokens burnt
     * @param reward -  the reward in wei that is released back to the sender
     */
    event LogBurn(address indexed sender, uint256 amountBurnt, uint256 reward);

    /**
     * @param _salt bytes32 salt to precommpute the erc1363 token address before deployment
     */
    constructor(bytes32 _salt) {
        tokenAddress = getAddress(getBytecode(), _salt);
        deployTokenContract(_salt);
        mithrilToken = MyERC1363Token(tokenAddress);
        bondingCurveDecimals = mithrilToken.decimals();
        multiple = 1;
        dec = 10 ** uint256(bondingCurveDecimals);
    }

    /**
     * @notice send ETH to trigger minting of mithril tokens.
     *         amount of mithril to be minted is controled by the state of linear bonding curve at any given time
     *
     */
    receive() external payable {
        uint256 tokensToMint = estimateTokenAmountForPrice(msg.value);
        mintMithril(msg.sender, tokensToMint);
    }

    /**
     * @notice Function that mints new mithril tokens
     *
     * @param _account -  EOA / contract which receives the newly minted Mithril
     * @param _amount -  // amount in TKNbits
     */
    function mintMithril(address _account, uint256 _amount) internal nonReentrant returns (bool) {
        uint256 priceForAmount = getMintPrice(_amount);
        require(msg.value >= priceForAmount);
        uint256 remainingFunds = msg.value.sub(priceForAmount);

        // Send back unspent funds
        if (remainingFunds > 0) {
            payable(_account).sendValue(remainingFunds);
        }

        mithrilToken.mint(_account, _amount);
        // increament pool balance
        poolBalance = poolBalance.add(msg.value.sub(remainingFunds));

        emit LogMint(_account, _amount, msg.value - remainingFunds);

        return true;

        // TODO: add any post mint functions ?
    }

    /**
     * @notice transfer Mithril tokens to this contract to received corresponding amount of ETH
     *
     * @dev Note: remember that the token contract address is always the message sender.
     *
     * @param spender The address which called `transferAndCall` or `transferFromAndCall` function
     * @param sender The address which are token transferred from
     * @param amount The amount of tokens transferred
     * @param data Additional data with no specified format
     *
     * @return `bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"))` unless throwing
     */
    function onTransferReceived(
        address spender,
        address sender,
        uint256 amount,
        bytes memory data
    ) public override returns (bytes4) {
        require(_msgSender() == address(mithrilToken), "FORBIDDEN: mithrilToken is not the message sender");

        emit TokensReceived(spender, sender, amount);

        uint256 reward = getBurnReward(amount);
        _burnTokensAndSendEth(payable(sender), amount, reward);

        return IERC1363Receiver.onTransferReceived.selector;
    }

    /**
     * @dev Called after validating a `onTransferReceived`. This function MAY throw to revert and reject the
     *      transfer. Return of other than the magic value MUST result in the
     *      transaction being reverted.
     *
     * @param transferAddress The address from which tokens are received
     * @param tokenAmount The amount of tokens to brun
     * @param reward The eth amount to send to the transferAddress after burning tokens
     *
     */
    function _burnTokensAndSendEth(
        address payable transferAddress,
        uint256 tokenAmount,
        uint256 reward
    ) internal nonReentrant {
        // // Check if the call was successful
        // require(success, "Token burn failed");
        //TODO: check if tokens transfered to this contract are now owned by this contract and burning them is correct
        // TDOO: or if we have manually reduce token supply and burntokensfrom tranferAddress
        mithrilToken.burn(tokenAmount); // can revert in certain situations

        poolBalance = poolBalance.sub(reward);

        transferAddress.sendValue(reward);

        emit LogBurn(transferAddress, tokenAmount, reward);

        // mithrilToken.burnFrom(spender, amount); // check successfull

        // sendEth(spender); // check successfull
    }

    /**
     * Get price for minting tokenAmount of tokens
     * @param tokenAmount token amount param
     * @return  finalPrice
     */
    function getMintPrice(uint256 tokenAmount) public view returns (uint256) {
        uint256 totalTokens = tokenAmount + mithrilToken.totalSupply();
        uint256 m = multiple;
        uint256 d = dec;
        // TODO: check overflow or try to convert to bancor formula
        uint256 finalPrice = (m * totalTokens * totalTokens) / (2 * d * d) - poolBalance;
        return finalPrice;
    }

    /**
     * Get burn reward for tokenAmount
     * @param tokenAmount token amount param
     * @return  finalPrice
     */
    // TODO: change the function name to getBurnReward
    function getBurnReward(uint256 tokenAmount) public view returns (uint256) {
        require(mithrilToken.totalSupply() >= tokenAmount);
        uint256 totalTokens = mithrilToken.totalSupply() - tokenAmount;
        uint256 m = multiple; // TODO: verify if m is mx from y = mx + b
        uint256 d = dec;
        // TODO: check overflow or try to convert to bancor formula
        // same as totalTokens^3
        uint256 finalPrice = poolBalance - (m * totalTokens * totalTokens) / (2 * d * d);
        return finalPrice;
    }

    /**
     * @dev calculates amount of tokens to mint for give Eth amount
     *      based on the area under the curve based on amount
     *      area = m * 1/2 * x ^ 2 <- total price of all tokens
     *      we can dervive
     *      poolBalance + msg.value = m * 1/2 * (totalSupply_ + newTokens) ^ 2
     *      first we figure out how many tokens to mint
     *      2 * (poolBalance + msg.value)^1/2 = m * (totalSupply_ + newTokens)
     * @param price - this is the amount of eth user sent to this cotract
     * @return tokenAmount
     */
    function estimateTokenAmountForPrice(uint256 price) public view returns (uint256 tokenAmount) {
        uint256 newTotal = Math.sqrt(((price + poolBalance) * 2) / multiple) * dec;
        return newTotal;
    }

    // TODO: double check answer is same and remove the user defined sqrt

    /**
     * @notice Function is used to deploy MyERC1363Token contract
     *
     * @param _salt - salt that determines the token address
     * @dev durng my interview i was asked about create2, i decided to implement this function as a practicle demo
     */
    function deployTokenContract(bytes32 _salt) internal {
        bytes memory bytecode = getBytecode();

        deploy(bytecode, _salt);
    }

    /**
     * @notice Function is used to deploy MyERC1363Token contract
     *         Takes the bytecode of the token contract + constructor arguments and deploys it
     *         to the blockchain unsing the CREATE2 opcode.
     *
     * @param _bytecode - bytecode of the token contract + constructor arguments
     * @param _salt - salt used to compute the address
     */
    function deploy(bytes memory _bytecode, bytes32 _salt) internal {
        address addr;

        assembly {
            addr := create2(
                0, // wei sent with current call
                add(_bytecode, 0x20), // Actual code starts after skipping the first 32 bytes
                mload(_bytecode), // Load the size of code contained in the first 32 bytes
                _salt // Salt from function arguments
            )

            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }
    }

    /**
     * @notice Function used to get the bytecode of the token contract + constructor arguments.
     *
     * @return bytes - bytecode of the token contract + constructor arguments
     * @dev our token contract does not expect any constructor arguments
     */
    function getBytecode() internal pure returns (bytes memory) {
        bytes memory bytecode = type(MyERC1363Token).creationCode;

        // return abi.encodePacked(bytecode, abi.encode(constructorArg1,constructorArg2));
        return abi.encodePacked(bytecode);
    }

    /**
     * Computes the address where the token contract is going to be deployed to.
     *
     * @param _bytecode - bytecode of the token contract + constructor arguments
     * @param _salt - salt used to compute the address
     *
     * @return address - address, where the contract is going to be deployed to
     */
    function getAddress(bytes memory _bytecode, bytes32 _salt) internal view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(_bytecode)));

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IERC1363Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
}
