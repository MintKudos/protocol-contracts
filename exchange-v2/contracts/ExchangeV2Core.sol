// SPDX-License-Identifier: MIT

pragma solidity >=0.6.2 <0.8.0;
pragma abicoder v2;

import "./LibFill.sol";
import "./LibOrder.sol";
import "./OrderValidator.sol";
import "./AssetMatcher.sol";
import "./TransferExecutor.sol";
import "./ITransferManager.sol";
import "./lib/LibTransfer.sol";

abstract contract ExchangeV2Core is Initializable, OwnableUpgradeable, AssetMatcher, TransferExecutor, OrderValidator, ITransferManager {
    using SafeMathUpgradeable for uint;
    using LibTransfer for address;

    uint256 private constant UINT256_MAX = 2 ** 256 - 1;

    //state of the orders
    mapping(bytes32 => uint) public fills;

    //events
    event Cancel(bytes32 hash);
    event Match(bytes32 leftHash, bytes32 rightHash, address leftMaker, address rightMaker, uint newLeftFill, uint newRightFill);

    function cancel(LibOrder.Order memory order) public {
        require(_msgSender() == order.maker, "not a maker");
        bytes32 orderKeyHash = LibOrder.hashKey(order);
        fills[orderKeyHash] = UINT256_MAX;
        emit Cancel(orderKeyHash);
    }

    function matchOrders(
        LibOrder.Order memory orderLeft,
        bytes memory signatureLeft,
        LibOrder.Order memory orderRight,
        bytes memory signatureRight
    ) public payable {
        validateFull(orderLeft, signatureLeft);
        validateFull(orderRight, signatureRight);
        if (orderLeft.taker != address(0)) {
            require(orderRight.maker == orderLeft.taker, "leftOrder.taker verification failed");
        }
        if (orderRight.taker != address(0)) {
            require(orderRight.taker == orderLeft.maker, "rightOrder.taker verification failed");
        }
        matchAndTransfer(orderLeft, orderRight);
    }

    function matchAndTransfer(LibOrder.Order memory orderLeft, LibOrder.Order memory orderRight) internal {
        (LibAsset.AssetType memory makeMatch, LibAsset.AssetType memory takeMatch) = matchAssets(orderLeft, orderRight);
        bytes32 leftOrderKeyHash = LibOrder.hashKey(orderLeft);
        bytes32 rightOrderKeyHash = LibOrder.hashKey(orderRight);
        uint leftOrderFill = fills[leftOrderKeyHash];
        uint rightOrderFill = fills[rightOrderKeyHash];
        //todo тут путаница в терминологии. до этого fill - это то чем уже заполнены. далее fill - это сколько будем дозаполнять
        //вроде там и там логично что это fill названо, но получается, что одним словом два разных понятия названы.
        //когда читаешь задаешься вопросом: зачем вычислять fill если уже есть fill? а нет, это разные fill, а в каком месте заканчивается по первому понятию и где начинается по второму?
        LibFill.FillResult memory fill = LibFill.fillOrder(orderLeft, orderRight, leftOrderFill, rightOrderFill);
        require(fill.takeValue > 0, "nothing to fill");

        address msgSender = _msgSender();
        if (msgSender != orderLeft.maker) {
            //todo если действие выполняет владелец ордера, то не учитываем частичное или полное выполнение ордера которое сейчас выполним?
            //  он может по этому ордеру скупить все что найдет с удовлетворяющей ценой без ограничения по количеству и ордер еще останется для дальнейших таких манипуляций
            //  а если он не хочет этим пользоваться, то нужно отдельной операцией отменять ордер? он отменится полностью. а может нужно было частично примениться как по правильному
            fills[leftOrderKeyHash] = leftOrderFill + fill.takeValue;
        }
        if (msgSender != orderRight.maker) {
            fills[rightOrderKeyHash] = rightOrderFill + fill.makeValue;
        }

        (uint totalMakeValue, uint totalTakeValue) = doTransfers(makeMatch, takeMatch, fill, orderLeft, orderRight);
        if (makeMatch.assetClass == LibAsset.ETH_ASSET_CLASS) {
            require(takeMatch.assetClass != LibAsset.ETH_ASSET_CLASS);
            require(msg.value >= totalMakeValue, "not enough eth");
            if (msg.value > totalMakeValue) {
                address(msg.sender).transferEth(msg.value - totalMakeValue);
            }
        } else if (takeMatch.assetClass == LibAsset.ETH_ASSET_CLASS) {
//            require(makeMatch.assetClass != LibAsset.ETH_ASSET_CLASS);//todo это не нужно проверять. с этим условием вошли в первую ветку if
            require(msg.value >= totalTakeValue, "not enough eth");
            if (msg.value > totalTakeValue) {
                address(msg.sender).transferEth(msg.value - totalTakeValue);
            }
        }
        emit Match(leftOrderKeyHash, rightOrderKeyHash, orderLeft.maker, orderRight.maker, fill.takeValue, fill.makeValue);
    }

    function matchAssets(LibOrder.Order memory orderLeft, LibOrder.Order memory orderRight) internal view returns (LibAsset.AssetType memory makeMatch, LibAsset.AssetType memory takeMatch) {
        makeMatch = matchAssets(orderLeft.makeAsset.assetType, orderRight.takeAsset.assetType);
        require(makeMatch.assetClass != 0, "assets don't match");
        takeMatch = matchAssets(orderLeft.takeAsset.assetType, orderRight.makeAsset.assetType);
        require(takeMatch.assetClass != 0, "assets don't match");
    }

    function validateFull(LibOrder.Order memory order, bytes memory signature) internal view {
        LibOrder.validate(order);
        validate(order, signature);
    }

    uint256[49] private __gap;
}
