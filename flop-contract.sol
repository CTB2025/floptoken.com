//    /$$$$$$  /$$                    
//   /$$__  $$| $$                    
//  | $$  \__/| $$  /$$$$$$   /$$$$$$ 
//  | $$$$    | $$ /$$__  $$ /$$__  $$
//  | $$_/    | $$| $$  \ $$| $$  \ $$
//  | $$      | $$| $$  | $$| $$  | $$
//  | $$      | $$|  $$$$$$/| $$$$$$$/
//  |__/      |__/ \______/ | $$____/  
//                          | $$      
//                          | $$      
//                          |__/       

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // For rescueTokens
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FLOP Token Contract
 * @notice An ERC20 token with fee deduction, XP rewards, minting, and automatic burning.
 * Fees are applied on normal transfers (including predictions) and are split among three channels:
 * - 1% is automatically burned (removed from circulation)
 * - 1% is sent to the prediction pool wallet
 * - 1% is sent to the buyback wallet
 * Airdrops are fee‑free by bypassing fee deduction.
 */
contract FLOP is ERC20, Ownable, ReentrancyGuard {
    // Initial supply: 300 trillion tokens (scaled by 10^18)
    uint256 public constant INITIAL_SUPPLY = 300_000_000_000_000 * 10**18;
    
    // Fee percentages (in percent; 1% each for burn, prediction pool, and buyback)
    uint256 public burnFee = 1;
    uint256 public predictionPoolFee = 1;
    uint256 public buybackFee = 1;

    // Fee wallet addresses
    address public predictionPool;
    address public buybackWallet;

    // XP system state variables
    mapping(address => uint256) private flopXP;
    mapping(address => bool) private authorizedContracts;
    bool public xpPaused = false;
    uint256 public constant MAX_XP_PER_TX = 10000;
    
    // Airdrop configuration: using a batch counter to track airdrops
    uint256 public currentAirdropBatch;
    mapping(uint256 => bool) private processedBatches;
    
    // Events for tracking operations
    event XPGranted(address indexed admin, address indexed user, uint256 amount);
    event XPSpent(address indexed admin, address indexed user, uint256 amount);
    event XPModified(address indexed contractCaller, address indexed user, int256 change);
    event XPSystemPaused(bool paused);
    event PredictionPlaced(address indexed user, uint256 amount, string prediction);
    event FlopXPUpdated(address indexed user, uint256 newXP);
    event BuybackExecuted(uint256 amount);
    event Burned(uint256 amount);

    /**
     * @dev Constructor mints the initial supply to the deployer and sets fee wallet addresses.
     * @param _predictionPool Address for the prediction pool wallet.
     * @param _buybackWallet Address for the buyback wallet.
     */
    constructor(address _predictionPool, address _buybackWallet) 
        ERC20("FLOP Coin", "FLOP") 
        Ownable(msg.sender)
    {
        require(_predictionPool != address(0), "Invalid prediction pool address");
        require(_buybackWallet != address(0), "Invalid buyback wallet address");

        _mint(msg.sender, INITIAL_SUPPLY);
        predictionPool = _predictionPool;
        buybackWallet = _buybackWallet;
    }

    /**
     * @dev Internal function that applies fee logic during transfers.
     * This function computes a total fee of 3% (split equally among burning,
     * the prediction pool, and the buyback wallet) and processes the fee accordingly.
     *
     * @param from Address sending tokens.
     * @param to Address receiving tokens.
     * @param amount Total amount being transferred.
     */
    function _transferWithFee(address from, address to, uint256 amount) internal {
        require(to != address(0), "FLOP: Transfer to zero address");
        require(amount > 0, "FLOP: Transfer amount must be greater than zero");

        // Calculate total fee percentage (should be 3)
        uint256 totalFeePercentage = burnFee + predictionPoolFee + buybackFee;
        // Compute the total fee amount (with rounding adjustment)
        uint256 feeAmount = (amount * totalFeePercentage + 50) / 100;
        uint256 transferAmount = amount - feeAmount;
        require(transferAmount <= amount && feeAmount <= amount, "Transfer or fee amount exceeds total");

        // Transfer net amount to the recipient.
        super._transfer(from, to, transferAmount);

        // Split feeAmount into three parts proportionally.
        uint256 burnAmount = (feeAmount * burnFee) / totalFeePercentage;
        uint256 predictionPoolAmount = (feeAmount * predictionPoolFee) / totalFeePercentage;
        uint256 buybackAmount = feeAmount - burnAmount - predictionPoolAmount;

        // Transfer fee to prediction pool.
        if (predictionPoolAmount > 0) {
            super._transfer(from, predictionPool, predictionPoolAmount);
        }
        // Transfer fee to buyback wallet.
        if (buybackAmount > 0) {
            super._transfer(from, buybackWallet, buybackAmount);
            emit BuybackExecuted(buybackAmount);
        }
        // Burn the fee portion designated for burning.
        if (burnAmount > 0) {
            _burn(from, burnAmount);
            emit Burned(burnAmount);
        }
    }

    /**
     * @dev Standard transfer function using the fee logic.
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transferWithFee(msg.sender, recipient, amount);
        return true;
    }

    /**
     * @dev Standard transferFrom function using the fee logic.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = allowance(sender, msg.sender);
        require(currentAllowance >= amount, "FLOP: Transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);
        _transferWithFee(sender, recipient, amount);
        return true;
    }

    /**
     * @dev Places a prediction by transferring tokens to the prediction pool.
     * Fees apply on this transfer and XP is awarded based on the prediction amount.
     *
     * @param amount Amount of tokens used for the prediction.
     * @param prediction A string representing the user's prediction.
     */
    function placePrediction(uint256 amount, string memory prediction) external {
        require(balanceOf(msg.sender) >= amount, "Not enough FLOP!");
        // Transfer tokens to the prediction pool (fees will be applied).
        _transferWithFee(msg.sender, predictionPool, amount);

        // Calculate XP earned (amount divided by 1024, rounded)
        uint256 xpEarned = (amount + 1023) >> 10;
        require(xpEarned <= amount, "XP earned exceeds prediction amount"); 
        flopXP[msg.sender] += xpEarned;

        emit PredictionPlaced(msg.sender, amount, prediction);
        emit FlopXPUpdated(msg.sender, flopXP[msg.sender]);
    }

    /**
     * @dev Performs an airdrop in batches.
     * Airdrops are executed fee‑free by directly calling the parent's _transfer.
     * Uses a batch counter to ensure each airdrop batch is processed only once.
     *
     * @param recipients Array of recipient addresses.
     * @param amountPerRecipient Amount of tokens per recipient.
     */
    function airdropBatch(address[] calldata recipients, uint256 amountPerRecipient) external onlyOwner nonReentrant {
        require(!processedBatches[currentAirdropBatch], "Batch already processed");
        
        // Mark the current batch as processed.
        processedBatches[currentAirdropBatch] = true;
        
        // Loop through recipients and transfer tokens fee‑free.
        for (uint256 i = 0; i < recipients.length; i++) {
            super._transfer(msg.sender, recipients[i], amountPerRecipient);
        }
        
        // Increment the batch counter for the next airdrop.
        currentAirdropBatch++;
    }
    
    /**
     * @dev Grants XP to a user. Only callable by authorized contracts or the owner.
     *
     * @param user Address of the user receiving XP.
     * @param amount Amount of XP to grant.
     */
    function grantFlopXP(address user, uint256 amount) external {
        require(!xpPaused, "XP functions are paused");
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized to grant XP");
        require(amount <= MAX_XP_PER_TX, "XP grant exceeds limit");
        flopXP[user] += amount;
        emit XPGranted(msg.sender, user, amount);
    }

    /**
     * @dev Spends XP from a user's balance. Only callable by authorized contracts or the owner.
     *
     * @param user Address of the user spending XP.
     * @param amount Amount of XP to spend.
     */
    function spendFlopXP(address user, uint256 amount) external nonReentrant {
        require(!xpPaused, "XP functions are paused");
        require(authorizedContracts[msg.sender] || msg.sender == owner(), "Not authorized to spend XP");
        require(flopXP[user] >= amount, "Not enough XP");
        flopXP[user] -= amount;
        emit XPSpent(msg.sender, user, amount);
    }

    /**
     * @dev Authorizes an external contract to interact with the XP system.
     * Only the owner can call this function.
     *
     * @param contractAddress Address of the contract to authorize.
     */
    function authorizeContract(address contractAddress) external onlyOwner {
        authorizedContracts[contractAddress] = true;
    }

    /**
     * @dev Revokes an external contract's authorization for the XP system.
     * Only the owner can call this function.
     *
     * @param contractAddress Address of the contract to revoke.
     */
    function revokeContractAuthorization(address contractAddress) external onlyOwner {
        authorizedContracts[contractAddress] = false;
    }

    /**
     * @dev Returns the current XP balance for a user.
     *
     * @param user Address of the user.
     * @return XP balance.
     */
    function getFlopXP(address user) external view returns (uint256) {
        return flopXP[user];
    }

    /**
     * @dev Toggles the XP system on or off.
     * Only the owner can call this function.
     */
    function toggleXPPaused() external onlyOwner {
        xpPaused = !xpPaused;
        emit XPSystemPaused(xpPaused);
    }
    
    /**
     * @dev Allows the owner to mint new tokens.
     * Minting bypasses fee logic since it calls the internal _mint function.
     * Use with caution, as additional minting can increase the total supply and affect token economics.
     *
     * @param to The address to receive the minted tokens.
     * @param amount The number of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    // --- Setter Functions for Updating Key Parameters ---
    
    /**
     * @dev Updates the prediction pool address.
     * Only the owner can call this.
     *
     * @param _predictionPool New address for the prediction pool wallet.
     */
    function setPredictionPool(address _predictionPool) external onlyOwner {
        require(_predictionPool != address(0), "Invalid address");
        predictionPool = _predictionPool;
    }
    
    /**
     * @dev Updates the buyback wallet address.
     * Only the owner can call this.
     *
     * @param _buybackWallet New address for the buyback wallet.
     */
    function setBuybackWallet(address _buybackWallet) external onlyOwner {
        require(_buybackWallet != address(0), "Invalid address");
        buybackWallet = _buybackWallet;
    }
    
    /**
     * @dev Updates the fee percentages for burning, prediction pool, and buyback.
     * Only the owner can call this.
     *
     * @param _burnFee New burn fee percentage.
     * @param _predictionPoolFee New prediction pool fee percentage.
     * @param _buybackFee New buyback fee percentage.
     */
    function setFees(uint256 _burnFee, uint256 _predictionPoolFee, uint256 _buybackFee) external onlyOwner {
        burnFee = _burnFee;
        predictionPoolFee = _predictionPoolFee;
        buybackFee = _buybackFee;
    }
    
    // --- Rescue Functions ---

    /**
     * @dev Allows the owner to rescue ERC20 tokens accidentally sent to this contract.
     * @param tokenAddress The address of the ERC20 token.
     * @param amount The amount of tokens to rescue.
     */
    function rescueTokens(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    /**
     * @dev Allows the owner to rescue ETH accidentally sent to this contract.
     * @param amount The amount of ETH to rescue.
     */
    function rescueETH(uint256 amount) external onlyOwner {
        payable(owner()).transfer(amount);
    }
    
    /**
     * @dev Fallback function to accept ETH.
     */
    receive() external payable {}
}
