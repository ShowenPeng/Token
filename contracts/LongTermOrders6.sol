// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./OrderPool.sol";
import "./BinarySearchTree.sol";
import "hardhat/console.sol";

///@notice This library handles the state and execution of long term orders.
library LongTermOrdersLib {
    using OrderPoolLib for OrderPoolLib.OrderPool;
    using BinarySearchTreeLib for BinarySearchTreeLib.Tree;
    using SafeERC20 for IERC20;

    ///@notice fee for LP providers, 4 decimal places, i.e. 30 = 0.3%
    uint256 public constant LP_FEE = 30;

    ///@notice information associated with a long term order
    struct Order {
        uint256 id;
        uint256 submitBlock;
        uint256 expirationBlock;
        uint256 saleRate;
        uint256 sellAmount;
        uint256 buyAmount;
        address owner;
        address sellTokenId;
        address buyTokenId;
    }

    ///@notice structure contains full state related to long term orders
    struct LongTermOrders {
        ///@notice minimum block interval between order expiries
        uint256 orderBlockInterval;
        ///@notice last virtual orders were executed immediately before this block
        uint256 lastVirtualOrderBlock;
        ///@notice token pair being traded in embedded amm
        address tokenA;
        address tokenB;
        ///@notice useful addresses for TWAMM transactions
        address refTWAMM;
        ///@notice mapping from token address to pool that is selling that token
        ///we maintain two order pools, one for each token that is tradable in the AMM
        mapping(address => OrderPoolLib.OrderPool) OrderPoolMap;
        ///@notice incrementing counter for order ids
        uint256 orderId;
        ///@notice mapping from order ids to Orders
        mapping(uint256 => Order) orderMap;
        ///@notice mapping from account address to its corresponding list of order ids
        mapping(address => uint256[]) orderIdMap;
        ///@notice mapping from order id to its status (false for nonactive true for active)
        mapping(uint256 => bool) orderIdStatusMap;
        ///@notice record all expiry blocks since the latest executed block
        BinarySearchTreeLib.Tree expiryBlockTreeSinceLastExecution;
    }

    ///@notice initialize state
    function initialize(
        LongTermOrders storage self,
        address tokenA,
        address tokenB,
        address refTWAMM,
        uint256 lastVirtualOrderBlock,
        uint256 orderBlockInterval
    ) public {
        self.tokenA = tokenA;
        self.tokenB = tokenB;
        self.refTWAMM = refTWAMM;
        self.lastVirtualOrderBlock = lastVirtualOrderBlock;
        self.orderBlockInterval = orderBlockInterval;
        self.expiryBlockTreeSinceLastExecution.insert(
            lastVirtualOrderBlock - (lastVirtualOrderBlock % orderBlockInterval)
        );
    }

    ///@notice long term swap token A for token B. Amount represents total amount being sold, numberOfBlockIntervals determines when order expires
    function longTermSwapFromAToB(
        LongTermOrders storage self,
        address sender,
        uint256 amountA,
        uint256 numberOfBlockIntervals,
        mapping(address => uint256) storage reserveMap
    ) public returns (uint256) {
        return
            performLongTermSwap(
                self,
                self.tokenA,
                self.tokenB,
                sender,
                amountA,
                numberOfBlockIntervals,
                reserveMap
            );
    }

    ///@notice long term swap token B for token A. Amount represents total amount being sold, numberOfBlockIntervals determines when order expires
    function longTermSwapFromBToA(
        LongTermOrders storage self,
        address sender,
        uint256 amountB,
        uint256 numberOfBlockIntervals,
        mapping(address => uint256) storage reserveMap
    ) public returns (uint256) {
        return
            performLongTermSwap(
                self,
                self.tokenB,
                self.tokenA,
                sender,
                amountB,
                numberOfBlockIntervals,
                reserveMap
            );
    }

    ///@notice adds long term swap to order pool
    function performLongTermSwap(
        LongTermOrders storage self,
        address from,
        address to,
        address sender,
        uint256 amount,
        uint256 numberOfBlockIntervals,
        mapping(address => uint256) storage reserveMap
    ) private returns (uint256) {
        //update virtual order state
        executeVirtualOrdersUntilSpecifiedBlock(self, reserveMap, block.number);

        //determine the selling rate based on number of blocks to expiry and total amount
        uint256 currentBlock = block.number;
        uint256 lastExpiryBlock = currentBlock -
            (currentBlock % self.orderBlockInterval);
        uint256 orderExpiry = self.orderBlockInterval *
            (numberOfBlockIntervals + 1) +
            lastExpiryBlock;
        uint256 sellingRate = amount / (orderExpiry - currentBlock);

        //add order to correct pool
        OrderPoolLib.OrderPool storage OrderPool = self.OrderPoolMap[from];
        OrderPool.depositOrder(self.orderId, sellingRate, orderExpiry);

        //add to order map
        self.orderMap[self.orderId] = Order(
            self.orderId,
            currentBlock,
            orderExpiry,
            sellingRate,
            0,
            0,
            sender,
            from,
            to
        );

        self.expiryBlockTreeSinceLastExecution.insert(orderExpiry);

        // add user's corresponding orderId to orderId mapping list content
        self.orderIdMap[sender].push(self.orderId);

        self.orderIdStatusMap[self.orderId] = true;

        return self.orderId++;
    }

    ///@notice cancel long term swap, pay out unsold tokens and well as purchased tokens
    function cancelLongTermSwap(
        LongTermOrders storage self,
        address sender,
        uint256 orderId,
        mapping(address => uint256) storage reserveMap
    ) public returns (uint256, uint256) {
        //update virtual order state
        executeVirtualOrdersUntilSpecifiedBlock(self, reserveMap, block.number);

        Order storage order = self.orderMap[orderId];

        require(self.orderIdStatusMap[orderId] = true, "Order Invalid");
        require(order.owner == sender, "Sender Must Be Order Owner");

        OrderPoolLib.OrderPool storage OrderPoolSell = self.OrderPoolMap[
            order.sellTokenId
        ];
        OrderPoolLib.OrderPool storage OrderPoolBuy = self.OrderPoolMap[
            order.buyTokenId
        ];

        (uint256 unsoldAmount, uint256 purchasedAmount) = OrderPoolSell
            .cancelOrder(orderId);
        require(
            unsoldAmount > 0 || purchasedAmount > 0,
            "No Proceeds To Withdraw"
        );

        order.sellAmount = (block.number - order.submitBlock) * order.saleRate;
        order.buyAmount += purchasedAmount;

        if (
            OrderPoolSell.salesRateEndingPerBlock[order.expirationBlock] == 0 &&
            OrderPoolBuy.salesRateEndingPerBlock[order.expirationBlock] == 0
        ) {
            self.expiryBlockTreeSinceLastExecution.deleteNode(
                order.expirationBlock
            );
        }

        // delete orderId from account list
        self.orderIdStatusMap[orderId] = false;

        //transfer to owner
        IERC20(order.buyTokenId).safeTransfer(self.refTWAMM, purchasedAmount);
        IERC20(order.sellTokenId).safeTransfer(self.refTWAMM, unsoldAmount);

        return (unsoldAmount, purchasedAmount);
    }

    ///@notice withdraw proceeds from a long term swap (can be expired or ongoing)
    function withdrawProceedsFromLongTermSwap(
        LongTermOrders storage self,
        address sender,
        uint256 orderId,
        mapping(address => uint256) storage reserveMap
    ) public returns (uint256) {
        //update virtual order state
        executeVirtualOrdersUntilSpecifiedBlock(self, reserveMap, block.number);

        Order storage order = self.orderMap[orderId];

        require(self.orderIdStatusMap[orderId] = true, "Order Invalid");
        require(order.owner == sender, "Sender Must Be Order Owner");

        OrderPoolLib.OrderPool storage OrderPool = self.OrderPoolMap[
            order.sellTokenId
        ];
        uint256 proceeds = OrderPool.withdrawProceeds(orderId);
        require(proceeds > 0, "No Proceeds To Withdraw");

        order.buyAmount += proceeds;

        if (order.expirationBlock <= block.number) {
            // delete orderId from account list
            self.orderIdStatusMap[orderId] = false;
            order.sellAmount =
                (order.expirationBlock - order.submitBlock) *
                order.saleRate;
        } else {
            order.sellAmount =
                (block.number - order.submitBlock) *
                order.saleRate;
        }

        //transfer to owner
        IERC20(order.buyTokenId).safeTransfer(self.refTWAMM, proceeds);

        return proceeds;
    }

    ///@notice executes all virtual orders between current lastVirtualOrderBlock and blockNumber
    //also handles orders that expire at end of final block. This assumes that no orders expire inside the given interval
    function executeVirtualTradesAndOrderExpiries(
        LongTermOrders storage self,
        mapping(address => uint256) storage reserveMap,
        uint256 blockNumber
    ) private {
        //amount sold from virtual trades
        uint256 blockNumberIncrement = blockNumber - self.lastVirtualOrderBlock;
        uint256 tokenASellAmount = self
            .OrderPoolMap[self.tokenA]
            .currentSalesRate * blockNumberIncrement;
        uint256 tokenBSellAmount = self
            .OrderPoolMap[self.tokenB]
            .currentSalesRate * blockNumberIncrement;

        //initial amm balance
        uint256 tokenAStart = reserveMap[self.tokenA];
        uint256 tokenBStart = reserveMap[self.tokenB];

        //updated balances from sales
        (
            uint256 tokenAOut,
            uint256 tokenBOut,
            uint256 ammEndTokenA,
            uint256 ammEndTokenB
        ) = computeVirtualBalances(
                tokenAStart,
                tokenBStart,
                tokenASellAmount,
                tokenBSellAmount
            );

        //charge LP fee
        ammEndTokenA += (tokenAOut * LP_FEE) / 10000;
        ammEndTokenB += (tokenBOut * LP_FEE) / 10000;

        tokenAOut = (tokenAOut * (10000 - LP_FEE)) / 10000;
        tokenBOut = (tokenBOut * (10000 - LP_FEE)) / 10000;

        //update balances reserves
        reserveMap[self.tokenA] = ammEndTokenA;
        reserveMap[self.tokenB] = ammEndTokenB;

        //distribute proceeds to pools
        OrderPoolLib.OrderPool storage OrderPoolA = self.OrderPoolMap[
            self.tokenA
        ];
        OrderPoolLib.OrderPool storage OrderPoolB = self.OrderPoolMap[
            self.tokenB
        ];

        OrderPoolA.distributePayment(tokenBOut);
        OrderPoolB.distributePayment(tokenAOut);

        //handle orders expiring at end of interval
        OrderPoolA.updateStateFromBlockExpiry(blockNumber);
        OrderPoolB.updateStateFromBlockExpiry(blockNumber);

        //update last virtual trade block
        self.lastVirtualOrderBlock = blockNumber;
    }

    ///@notice executes all virtual orders until specified block, includ current block.
    function executeVirtualOrdersUntilSpecifiedBlock(
        LongTermOrders storage self,
        mapping(address => uint256) storage reserveMap,
        uint256 blockNumber
    ) public {
        require(
            blockNumber <= block.number &&
                blockNumber >= self.lastVirtualOrderBlock,
            "Specified Block Number Invalid!"
        );

        OrderPoolLib.OrderPool storage OrderPoolA = self.OrderPoolMap[
            self.tokenA
        ];
        OrderPoolLib.OrderPool storage OrderPoolB = self.OrderPoolMap[
            self.tokenB
        ];

        // get list of expiryBlocks given points that are divisible by int blockInterval
        // then trim the tree to have root tree to be node correponding to the last argument (%5=0)
        self.expiryBlockTreeSinceLastExecution.processExpiriesListNTrimTree(
            self.lastVirtualOrderBlock -
                (self.lastVirtualOrderBlock % self.orderBlockInterval),
            blockNumber - (blockNumber % self.orderBlockInterval)
        );
        uint256[] storage expiriesList = self
            .expiryBlockTreeSinceLastExecution
            .getExpiriesList();

        for (uint256 i = 0; i < expiriesList.length; i++) {
            if (
                (OrderPoolA.salesRateEndingPerBlock[expiriesList[i]] > 0 ||
                    OrderPoolB.salesRateEndingPerBlock[expiriesList[i]] > 0) &&
                (expiriesList[i] > self.lastVirtualOrderBlock &&
                    expiriesList[i] < blockNumber)
            ) {
                executeVirtualTradesAndOrderExpiries(
                    self,
                    reserveMap,
                    expiriesList[i]
                );
            }
        }

        executeVirtualTradesAndOrderExpiries(self, reserveMap, blockNumber);
    }

    ///@notice computes the result of virtual trades by the token pools
    function computeVirtualBalances(
        uint256 tokenAStart,
        uint256 tokenBStart,
        uint256 tokenAIn,
        uint256 tokenBIn
    )
        private
        view
        returns (
            uint256 tokenAOut,
            uint256 tokenBOut,
            uint256 ammEndTokenA,
            uint256 ammEndTokenB
        )
    {
        //constant product formula
        tokenAOut =
            ((tokenAStart + tokenAIn) * tokenBIn) /
            (tokenBStart + tokenBIn);
        console.log("tokenAOut", tokenAOut);
        tokenBOut =
            ((tokenBStart + tokenBIn) * tokenAIn) /
            (tokenAStart + tokenAIn);
        console.log("tokenBOut", tokenBOut);
        ammEndTokenA = tokenAStart + tokenAIn - tokenAOut;
        console.log("ammEndTokenA", ammEndTokenA);
        ammEndTokenB = tokenBStart + tokenBIn - tokenBOut;
        console.log("ammEndTokenB", ammEndTokenB);
    }
}
