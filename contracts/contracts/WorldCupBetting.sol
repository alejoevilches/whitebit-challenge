// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
}
/**
 * @title WorldCupBetting
 * @notice Assessment entrypoint: replace stub bodies with a full prediction market until
 *         `test/WorldCupBetting.assessment.test.ts` passes. Out-of-the-box, every call reverts so
 *         the assessment suite is red until you implement behavior.
 * @dev Optional behavioral reference in-repo: `PredictionMarket.sol` (do not modify that file
 *      unless your interview allows it). Instructors can run tests against the reference by
 *      setting `WORLD_CUP_ASSESSMENT_SOLUTION=1` when executing Hardhat (see `assessment/instructions.md`).
 */
contract WorldCupBetting is ReentrancyGuard, Ownable {
    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address creator;
        uint256 createdAt;
        MarketStatus status;
        uint256 winningOutcome;
        address tokenAddress;
        uint256 totalVolume;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        bool claimed;
    }

    IReputationSystem public reputationSystem;
    uint256 public marketCount;
    uint256 public betCount;
    uint256 public constant PLATFORM_FEE = 2;
    uint256 public constant FEE_DENOMINATOR = 100;

    mapping(uint256 => Market) markets;
    mapping(uint256 => Bet) bets;
    mapping(uint256 => uint256[]) public marketBets;
    mapping(address => uint256[]) public userBets;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomePools;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomeShares;
    mapping(address => uint256) public collectedFees;
    mapping(uint256 => bool) public positionsForSale;
    mapping(uint256 => uint256) public positionPrices;

    event MarketCreated(uint256 marketCount, address creator, string question);
    event MarketResolved(uint256 marketCount, uint256 winningOutcome);
    event WinningsClaimed(uint256 betId, address bettor, uint256 payout);
    event FeesWithdrawn(address token, uint256 amount, address to);
    event PositionListed(uint256 betId, uint256 amount);
    event PositionSold(uint256 betId, address seller, address sender, uint256 amount);

    constructor(address _reputationSystem) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(_reputationSystem);
    }

    function createMarket(
        string memory question,
        string memory description,
        string[] memory outcomes,
        uint256 resolutionTime,
        address oracleAddress,
        address tokenAddress
    ) external returns (uint256) {
        require(outcomes.length >= 2, "Need at least 2 outcomes");
        require(resolutionTime >= block.timestamp, "Resolution must be in future");
        require(oracleAddress != address(0), "Invalid arbitrator");

        marketCount++;
        Market storage newMarket = markets[marketCount];
        newMarket.id = marketCount;
        newMarket.question = question;
        newMarket.description = description;
        newMarket.outcomes = outcomes;
        newMarket.resolutionTime = resolutionTime;
        newMarket.arbitrator = oracleAddress;
        newMarket.tokenAddress = tokenAddress;
        newMarket.creator = msg.sender;
        newMarket.createdAt = block.timestamp;
        newMarket.status = MarketStatus.Open;

        emit MarketCreated(marketCount, msg.sender, question);
        return marketCount;
    }

    function placeBet(uint256 id, uint256 outcomeIndex, uint256 amount, uint256 minimum) external payable returns (uint256) {
        Market storage selectedMarket = markets[id];

        require(selectedMarket.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < selectedMarket.resolutionTime, "Market closed");
        require(outcomeIndex < selectedMarket.outcomes.length, "Invalid outcome");
        require(amount > 0, "Invalid amount");

        uint256 shares = calculateShares(id, outcomeIndex, amount);
        require(shares >= minimum, "Slippage exceeded");

        if (selectedMarket.tokenAddress == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            IERC20(selectedMarket.tokenAddress).transferFrom(msg.sender, address(this), amount);
        }

        betCount++;
        Bet storage bet = bets[betCount];
        bet.id = betCount;
        bet.bettor = msg.sender;
        bet.marketId = id;
        bet.outcomeIndex = outcomeIndex;
        bet.amount = amount;
        bet.shares = shares;
        bet.timestamp = block.timestamp;

        marketBets[id].push(betCount);
        userBets[msg.sender].push(betCount);

        outcomePools[id][outcomeIndex] += amount;
        outcomeShares[id][outcomeIndex] += shares;
        selectedMarket.totalVolume += amount;

        return betCount;
    }

    function resolveMarket(uint256 id, uint256 winningOutcome) external {
        Market storage market = markets[id];

        require(market.status == MarketStatus.Open, "Market not open");
        require(block.timestamp >= market.resolutionTime, "Too early");
        
        require(msg.sender == market.arbitrator, "Only arbitrator");
        require(winningOutcome < market.outcomes.length, "Invalid outcome");

        market.status = MarketStatus.Resolved;
        market.winningOutcome = winningOutcome;

        emit MarketResolved(id, winningOutcome);
    }

    function claimWinnings(uint256 betId) external nonReentrant {
        Bet storage bet = bets[betId];
        Market storage market = markets[bet.marketId];
        require(msg.sender == bet.bettor, "Not your bet");
        require(market.status == MarketStatus.Resolved, "Market not resolved");
        require(!bet.claimed, "Already claimed");

        if (bet.outcomeIndex == market.winningOutcome) {
            bet.claimed = true;

            uint256 totalWinningShares = outcomeShares[bet.marketId][market.winningOutcome];
            uint256 totalPool = getTotalPool(bet.marketId);

            uint256 payout = (bet.shares * totalPool) / totalWinningShares;
            uint256 fee = (payout * PLATFORM_FEE) / FEE_DENOMINATOR;
            uint256 netPayout = payout - fee;
            collectedFees[market.tokenAddress] += fee;

            reputationSystem.updateReputation(msg.sender, true);

            if (market.tokenAddress == address(0)) {
                (bool success, ) = payable(msg.sender).call{value: netPayout}("");
                require(success, "ETH transfer failed");
            } else {
                IERC20(market.tokenAddress).transfer(msg.sender, netPayout);
            }

            emit WinningsClaimed(betId, msg.sender, netPayout);
        } else {
            bet.claimed = true;
            reputationSystem.updateReputation(msg.sender, false);
        }
    }

    function listPosition(uint256 betId, uint256 amount) external {
        Bet storage bet = bets[betId];
        require(msg.sender == bet.bettor, "Not your bet");
        require(!bet.claimed, "Bet already claimed");
        require(markets[bet.marketId].status == MarketStatus.Open, "Market not open");
        require(amount > 0, "Invalid amount");

        positionsForSale[betId] = true;
        positionPrices[betId] = amount;

        emit PositionListed(betId, amount);
    }

    function cancelListing(uint256 betId) external {
        Bet storage bet = bets[betId];

        require(msg.sender == bet.bettor, "Not your bet");
        require(positionsForSale[betId], "Position not for sale");

        positionsForSale[betId] = false;
        positionPrices[betId] = 0;
    }

    function buyPosition(uint256 betId) external payable nonReentrant {
        require(positionsForSale[betId], "Position not for sale");

        Bet storage bet = bets[betId];
        Market storage market = markets[bet.marketId];
        address seller = bet.bettor;
        uint256 price = positionPrices[betId];

        require(!bet.claimed, "Bet already claimed");
        require(market.status == MarketStatus.Open, "Market not open");
        require(msg.sender != seller, "Cannot buy own position");

        // Update ownership
        bet.bettor = msg.sender;
        positionsForSale[betId] = false;
        positionPrices[betId] = 0;

        // Update userBets mapping for new owner
        userBets[msg.sender].push(betId);

        // Transfer payment to seller (use market's token type)
        if (market.tokenAddress == address(0)) {
            // ETH market - payment in ETH
            require(msg.value >= price, "Insufficient ETH");
            (bool success, ) = payable(seller).call{value: price}("");
            require(success, "ETH transfer failed");

            // Refund excess
            if (msg.value > price) {
                (bool refundSuccess, ) = payable(msg.sender).call{value: msg.value - price}("");
                require(refundSuccess, "Refund failed");
            }
        } else {
            // ERC20 market - payment in ERC20
            require(msg.value == 0, "Do not send ETH for ERC20 market");
            IERC20(market.tokenAddress).transferFrom(msg.sender, seller, price);
        }

        emit PositionSold(betId, seller, msg.sender, price);
    }

    function withdrawFees(address tokenAddress) external onlyOwner nonReentrant {
        uint256 fees = collectedFees[tokenAddress];
        require(fees > 0, "No fees to withdraw");

        collectedFees[tokenAddress] = 0;

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(owner()).call{value: fees}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(tokenAddress).transfer(owner(), fees);
        }

        emit FeesWithdrawn(tokenAddress, fees, owner());
    }

    function getAvailableFees(address tokenAddress) external view returns (uint256) {
        return collectedFees[tokenAddress];
    }

    function calculateShares(uint256 marketId, uint256 outcomeIndex, uint256 amount) public view returns (uint256) {
        uint256 currentPool = outcomePools[marketId][outcomeIndex];
        if (currentPool == 0) return amount * 100;

        uint256 totalPool = getTotalPool(marketId);
        uint256 newPool = currentPool + amount;

        return (amount * 100 * totalPool) / (newPool * currentPool);
    }

    function getPrice(uint256 marketId, uint256 outcomeIndex) public view returns (uint256) {
        uint256 pool = outcomePools[marketId][outcomeIndex];
        uint256 total = getTotalPool(marketId);

        if (total == 0) return 50;
        return (pool * 100) / total;
    }

    function getTotalPool(uint256 marketId) public view returns (uint256) {
        Market storage market = markets[marketId];
        uint256 total = 0;
        for (uint256 i = 0; i < market.outcomes.length; i++) {
            total += outcomePools[marketId][i];
        }
        return total;
    }

    function getUserBets(address user) external view returns (uint256[] memory) {
        return userBets[user];
    }

    function getMarketBets(uint256 marketId) external view returns (uint256[] memory) {
        return marketBets[marketId];
    }

    function getMarket(uint256 id)
        external
        view
        returns (
            uint256 marketId,
            string memory question,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address creator,
            MarketStatus status,
            uint256 totalVolume,
            address tokenAddress
        )
    {
        Market storage m = markets[id];
        return (
            m.id,
            m.question,
            m.description,
            m.outcomes,
            m.resolutionTime,
            m.arbitrator,
            m.creator,
            m.status,
            m.totalVolume,
            m.tokenAddress
        );
    }
}
