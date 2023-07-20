// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./MyERC1363Token.sol";
import "./BancorFormula.sol";

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

contract LbcTokenSwap is IERC1363Receiver, ERC165, BancorFormula, Context, ReentrancyGuard, Ownable {
    //FIXME: add mechanism to mitigate front running attacks

    using SafeMath for uint256;

    using Address for address payable; // prettier-ignore

    // uint32 private constant MAX_WEIGHT = 1000000;

    /**
     * @dev reserve ratio, represented in ppm, 1-1000000
     *      1/3 corresponds to y= multiple * x^2
     *      1/2 corresponds to y= multiple * x
     *      2/3 corresponds to y= multiple * x^1/2
     *      multiple will depends on contract initialization,
     *      specificallytotalAmount and poolBalance parameters
     *      we might want to add an 'initialize' function that will allow
     *      the owner to send ether to the contract and mint a given amount of tokens
     */
    uint32 public immutable reserveRatio;

    // ERC1363 token which is accepted
    MyERC1363Token public mithrilToken;

    // the address of the token which will be deployed and is used in the linear bonding curver
    address public immutable tokenAddress;

    /**
     * - to prevent front running attacks
     * - gas price limit prevents users from having control over the order of execution
     */

    uint256 public gasPrice = 0 wei;

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

    // verifies that the gas price is lower than the universal limit
    modifier isGasPriceValid() {
        require(tx.gasprice <= gasPrice, "FORBIDDEN: Invalid gas price");
        _;
    }

    /**
     * @param _salt bytes32 salt to precommpute the erc1363 token address before deployment
     * @param _reserveRatio to set reserveRatio for the curver
     * @param _initialSupply bootstrap liquidity by minting an initial supply
     */
    constructor(bytes32 _salt, uint32 _reserveRatio, uint256 _initialSupply, uint256 _gasPrice) {
        tokenAddress = getAddress(getBytecode(), _salt);
        deployTokenContract(_salt);
        mithrilToken = MyERC1363Token(tokenAddress);
        mithrilToken.mint(msg.sender, _initialSupply);
        reserveRatio = _reserveRatio;
        gasPrice = _gasPrice;
    }

    /**
     * @notice send ETH to trigger minting of mithril tokens.
     *         amount of mithril to be minted is controled by the state of linear bonding curve at any given time
     *
     */
    receive() external payable {
        // increament pool balance
        require(msg.value > 0, "FORBIDDEN: only nonzero eth values are accepted");
        require(tx.gasprice <= gasPrice, "FORBIDDEN: Invalid gas price");
        poolBalance = poolBalance.add(msg.value);
        uint256 tokensToMint = estimateTokenAmountForPrice(msg.value);
        mintMithril(msg.sender, tokensToMint);
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
        uint256 tokensToMint = calculatePurchaseReturn(mithrilToken.totalSupply(), poolBalance, reserveRatio, price);
        return tokensToMint;
    }

    /**
     * @notice Function that mints new mithril tokens
     *
     * @param _account -  EOA / contract which receives the newly minted Mithril
     * @param _amount -  // amount in TKNbits
     */
    function mintMithril(address _account, uint256 _amount) internal isGasPriceValid returns (bool) {
        mithrilToken.mint(_account, _amount);

        emit LogMint(_account, _amount, msg.value);

        return true;
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
    ) internal isGasPriceValid nonReentrant {
        mithrilToken.burn(tokenAmount); // can revert in certain situations

        poolBalance = poolBalance.sub(reward);

        transferAddress.sendValue(reward);

        emit LogBurn(transferAddress, tokenAmount, reward);
    }

    /**
     * Get burn reward for tokenAmount
     * @param tokenAmount token amount param
     * @return  finalPrice
     */
    function getBurnReward(uint256 tokenAmount) public view returns (uint256) {
        return calculateSaleReturn(mithrilToken.totalSupply(), poolBalance, reserveRatio, tokenAmount);
    }

    /**
     * @dev Allows the owner to update the gas price limit
     * @param _gasPrice The new gas price limit
     *
     */
    function setGasPrice(uint256 _gasPrice) public onlyOwner {
        require(_gasPrice > 0, "FORBIDDEN: gas price cannot be zero");
        gasPrice = _gasPrice;
    }

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
}
