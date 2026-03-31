
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IVerifierProxy} from "@chainlink/contracts/src/v0.8/llo-feeds/v0.5.0/interfaces/IVerifierProxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceManager} from "src/interfaces/IPriceManager.sol";

import {EmergencyWithdrawer} from "src/EmergencyWithdrawer.sol";
import {LinkReceiver} from "src/LinkReceiver.sol";
import {PausableWithAccessControl} from "src/PausableWithAccessControl.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Roles} from "src/libraries/Roles.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title PriceManager Contract.
/// @notice This contract implements functionality to verify and store Data Streams reports from
/// the Data Streams API. It also provides a fallback mechanism to use Chainlink data feeds in case
/// the Data Streams prices are stale.
abstract contract PriceManager is LinkReceiver, EmergencyWithdrawer, IPriceManager {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeCast for int256;
  using SafeCast for uint256;

  /// @notice This event is emitted when an asset is added to the allow list
  /// @param asset The address of the asset that was added to the allow list
  event AssetAddedToAllowlist(address asset);
  /// @notice This event is emitted when an asset is removed from the allowlist
  /// @param asset The address of the asset that was removed from the allowlist
  event AssetRemovedFromAllowlist(address asset);
  /// @notice This event is emitted when the VerifierProxy address is set.
  /// @param verifierProxy The address of the new VerifierProxy contract.
  event VerifierProxySet(address verifierProxy);
  /// @notice This event is emitted when a new asset price is transmitted.
  /// @param asset The address of the asset.
  /// @param price The new price of the asset, scaled to 18 decimals.
  event PriceTransmitted(address indexed asset, uint256 price);
  /// @notice This event is emitted when Data Streams feed information is updated.
  /// @param asset The address of the asset.
  /// @param feedInfo The data streams and data feeds infos for the asset.
  event FeedInfoUpdated(address indexed asset, FeedInfo feedInfo);

  /// @notice This error is thrown when an unsupported report version is encountered.
  /// @param reportVersion The unsupported report version.
  error InvalidFeedVersion(bytes32 dataStreamsFeedId, uint16 reportVersion);
  /// @notice This error is thrown when trying to set an invalid feed decimals e.g. zero for a Streams data or a
  /// different value that the on-chain data feed.
  /// @param dataStreamsFeedId The dataStreamsFeedId with invalid decimals.
  error InvalidFeedDecimals(bytes32 dataStreamsFeedId);
  /// @notice This error is thrown when trying to transmit a report for a feed that is not allowlisted.
  /// @param dataStreamsFeedId The non-allowlisted dataStreamsFeedId.
  error FeedNotAllowlisted(bytes32 dataStreamsFeedId);

  /// @notice Data Streams report schema v3 (crypto streams).
  struct ReportV3 {
    bytes32 dataStreamsFeedId; //                 Unique identifier for the data stream.
    uint32 validFromTimestamp; // ───╮ Start timestamp of price validity period (seconds).
    uint32 observationsTimestamp; // │ End timestamp of price validity period (seconds).
    uint192 nativeFee; // ───────────╯ Verification cost in native blockchain tokens.
    uint192 linkFee; // ─────────────╮ Verification cost in LINK tokens.
    uint32 expiresAt; //─────────────╯ Timestamp when this report expires (seconds).
    int192 price; //                   DON consensus median price.
    int192 bid; //                     Simulated buy impact price at X% liquidity depth.
    int192 ask; //                     Simulated sell impact price at X% liquidity depth.
  }

  /// @notice The parameters for adding or updating feed information.
  struct FeedInfo {
    bytes32 dataStreamsFeedId; //                       Unique identifier for the data stream.
    AggregatorV3Interface usdDataFeed; // ─╮ Address of the data feed usd feed.
    uint32 stalenessThreshold; //          │ Maximum age of the price data (seconds).
    uint8 dataStreamsFeedDecimals; // ─────╯ Number of decimals in the reported price.
  }

  /// @notice The parameters for adding or updating feed information.
  struct ApplyFeedInfoUpdateParams {
    address asset; // Address of the asset.
    FeedInfo feedInfo; // The asset feeds configurations.
  }

  /// @notice Stored price information.
  struct DataStreamsPriceInfo {
    uint224 usdPrice; // ─╮ USD price scaled to 18 decimals.
    uint32 timestamp; // ─╯ Timestamp of the price (seconds).
  }

  /// @notice The Data Streams report schema version supported by this contract.
  uint256 private constant STREAMS_REPORT_V3 = 3;
  /// @notice The number of decimals to which prices are scaled to (18).
  uint256 internal constant PRICE_DECIMALS = 18;

  /// @notice The Data Streams VerifierProxy contract.
  IVerifierProxy internal immutable i_streamsVerifierProxy;

  /// @notice Array of all the enabled auction for this contract.
  EnumerableSet.AddressSet internal s_allowlistedAssets;

  /// @notice Mapping of asset addresses to their USD data feed contracts.
  mapping(address asset => FeedInfo feedInfo) internal s_feedInfo;
  /// @notice Mapping of Data Streams feed IDs to asset.
  mapping(bytes32 dataStreamsFeedId => address asset) internal s_dataStreamsFeedIdToAsset;
  /// @notice Mapping of asset to data streams transmitted price.
  mapping(address asset => DataStreamsPriceInfo streamsPrice) internal s_dataStreamsPrice;

  constructor(
    uint48 adminRoleTransferDelay,
    address admin,
    address verifierProxy,
    address linkToken,
    ApplyFeedInfoUpdateParams[] memory feedsInfo
  ) LinkReceiver(linkToken) EmergencyWithdrawer(adminRoleTransferDelay, admin) {
    if (verifierProxy == address(0)) {
      revert Errors.InvalidZeroAddress();
    }

    i_streamsVerifierProxy = IVerifierProxy(verifierProxy);

    if (feedsInfo.length > 0) {
      _applyFeedInfoUpdates(feedsInfo, new address[](0));
    }

    emit VerifierProxySet(verifierProxy);
  }

  // ================================================================================================
  // │                                      Price Transmission                                      │
  // ================================================================================================

  /// @inheritdoc IPriceManager
  /// @dev - The function does not handle LINK fee payment to the VerifierProxy, it is assumed that fees are waived.
  function transmit(
    bytes[] calldata unverifiedReports
  ) external onlyRole(Roles.PRICE_ADMIN_ROLE) {
    if (unverifiedReports.length == 0) {
      revert Errors.EmptyList();
    }

    for (uint256 i; i < unverifiedReports.length; ++i) {
      // Decode the unverified report.
      (, bytes memory reportData,,,) =
        abi.decode(unverifiedReports[i], (bytes32[3], bytes, bytes32[], bytes32[], bytes32));

      bytes32 dataStreamsFeedId = bytes32(reportData);

      if (s_dataStreamsFeedIdToAsset[dataStreamsFeedId] == address(0)) {
        revert FeedNotAllowlisted(dataStreamsFeedId);
      }
    }

    // Verify report through the proxy, decode & store prices.
    bytes[] memory verifiedReports = i_streamsVerifierProxy.verifyBulk(unverifiedReports, abi.encode(i_linkToken));

    for (uint256 i; i < verifiedReports.length; ++i) {
      ReportV3 memory report = abi.decode(verifiedReports[i], (ReportV3));
      address asset = s_dataStreamsFeedIdToAsset[report.dataStreamsFeedId];
      FeedInfo storage feedInfo = s_feedInfo[asset];

      uint256 usdPrice = int256(report.price).toUint256();

      if (report.observationsTimestamp < block.timestamp - feedInfo.stalenessThreshold) {
        revert Errors.StaleFeedData();
      }

      // Scale price to 18 decimals.
      uint8 feedDecimals = feedInfo.dataStreamsFeedDecimals;
      if (feedDecimals < PRICE_DECIMALS) {
        usdPrice = (usdPrice * 10 ** (PRICE_DECIMALS - feedDecimals));
      } else if (feedDecimals > PRICE_DECIMALS) {
        usdPrice = (usdPrice / 10 ** (feedDecimals - PRICE_DECIMALS));
      }

      if (usdPrice == 0) {
        revert Errors.ZeroFeedData();
      }

      s_dataStreamsPrice[asset] =
        DataStreamsPriceInfo({usdPrice: usdPrice.toUint224(), timestamp: report.observationsTimestamp});

      emit PriceTransmitted(asset, usdPrice);
    }
  }

  // ================================================================================================
  // │                                       Feeds Management                                       │
  // ================================================================================================

  /// @notice Adds, updates or removes feeds information.
  /// @dev precondition - the caller must have the ASSET_ADMIN_ROLE.
  /// @param adds List of feed information to add or update.
  /// @param removes List of assets to remove.
  function applyFeedInfoUpdates(
    ApplyFeedInfoUpdateParams[] memory adds,
    address[] memory removes
  ) external onlyRole(Roles.ASSET_ADMIN_ROLE) {
    _applyFeedInfoUpdates(adds, removes);
  }

  /// @notice Internal function to add, update or remove feeds information.
  /// @dev precondition - the adds and removes lists must not both be empty.
  /// @dev precondition - removed asset must be already allowlisted.
  /// @dev precondition - added/updated feed asset address must not be zero.
  /// @dev precondition - added/updated feed data feed address and data streams feed id must not both be zero.
  /// @dev precondition - added/updated feed decimals must be greater than zero.
  /// @dev precondition - added/updated when data streams feed id is set it must be of version 3.
  /// @param adds List of feed information to add or update (allowlists new assets).
  /// @param removes List of assets to remove (removes assets from allowlist and clean up feed info state).
  function _applyFeedInfoUpdates(
    ApplyFeedInfoUpdateParams[] memory adds,
    address[] memory removes
  ) internal {
    if (adds.length == 0 && removes.length == 0) {
      revert Errors.EmptyList();
    }

    for (uint256 i; i < removes.length; ++i) {
      address asset = removes[i];

      _onFeedInfoUpdate(asset, true);

      if (!s_allowlistedAssets.remove(asset)) {
        revert Errors.AssetNotAllowlisted(asset);
      }

      delete s_dataStreamsFeedIdToAsset[s_feedInfo[asset].dataStreamsFeedId];
      delete s_feedInfo[asset];
      delete s_dataStreamsPrice[asset];

      emit AssetRemovedFromAllowlist(asset);
    }

    for (uint256 i; i < adds.length; ++i) {
      FeedInfo memory feedInfo = adds[i].feedInfo;
      address asset = adds[i].asset;

      _onFeedInfoUpdate(asset, false);

      if (asset == address(0)) {
        revert Errors.InvalidZeroAddress();
      }

      if (
        feedInfo.stalenessThreshold == 0
          || (feedInfo.dataStreamsFeedId == bytes32(0) && feedInfo.usdDataFeed == AggregatorV3Interface(address(0)))
      ) {
        revert Errors.InvalidZeroValue();
      }

      if (feedInfo.dataStreamsFeedId != bytes32(0)) {
        bytes32 dataStreamsFeedId = feedInfo.dataStreamsFeedId;

        if (feedInfo.dataStreamsFeedDecimals == 0) {
          revert InvalidFeedDecimals(dataStreamsFeedId);
        }

        uint16 version = uint16(bytes2(dataStreamsFeedId));

        if (version != STREAMS_REPORT_V3) {
          revert InvalidFeedVersion(dataStreamsFeedId, version);
        }

        // Look up previous owner of this feed ID before overwriting; clean up that asset's data streams state
        // if the feed ID is being rotated to a different asset.
        address previousAssetForFeedId = s_dataStreamsFeedIdToAsset[feedInfo.dataStreamsFeedId];
        if (previousAssetForFeedId != address(0) && previousAssetForFeedId != asset) {
          FeedInfo storage previousAssetFeedInfo = s_feedInfo[previousAssetForFeedId];

          // Since the rotation is causing the Data Streams feed to be removed for the previous asset, we need to ensure
          // there is still a valid price source for that asset.
          if (address(previousAssetFeedInfo.usdDataFeed) == address(0)) {
            revert Errors.InvalidZeroValue();
          }

          previousAssetFeedInfo.dataStreamsFeedId = bytes32(0);
          previousAssetFeedInfo.dataStreamsFeedDecimals = 0;
          delete s_dataStreamsPrice[previousAssetForFeedId];
        }

        if (previousAssetForFeedId != asset) s_dataStreamsFeedIdToAsset[feedInfo.dataStreamsFeedId] = asset;
      }

      FeedInfo storage existingFeedInfo = s_feedInfo[asset];

      if (s_allowlistedAssets.add(asset)) {
        emit AssetAddedToAllowlist(asset);
      } else if (existingFeedInfo.dataStreamsFeedId != feedInfo.dataStreamsFeedId) {
        // If we are updating the feed ID for an already allowlisted asset, we need to clean up the old feed ID to asset
        // mapping and the old price, as they will no longer be valid.
        delete s_dataStreamsFeedIdToAsset[existingFeedInfo.dataStreamsFeedId];
        delete s_dataStreamsPrice[asset];
      }

      s_feedInfo[asset] = FeedInfo({
        dataStreamsFeedId: feedInfo.dataStreamsFeedId,
        usdDataFeed: feedInfo.usdDataFeed,
        dataStreamsFeedDecimals: feedInfo.dataStreamsFeedDecimals,
        stalenessThreshold: feedInfo.stalenessThreshold
      });

      emit FeedInfoUpdated(asset, feedInfo);
    }
  }

  /// @dev This empty hook is provided to allow inheriting contracts to implement custom logic that should be executed
  /// when feed information is updated, e.g. adding state dependant checks, emitting additional events, updating
  /// auxiliary state, etc.
  /// @param asset The address of the asset whose feed information was updated.
  /// @param isRemoved Whether the feed information was removed or added/updated - true if removed, false if added or
  /// updated.
  function _onFeedInfoUpdate(
    address asset,
    bool isRemoved
  ) internal virtual {}

  // ================================================================================================
  // │                                           Getters                                            │
  // ================================================================================================

  /// @notice Getter function to retrieve the address of the Data Streams VerifierProxy contract.
  /// @return streamsVerifierProxy The address of the Data Streams VerifierProxy contract.
  function getStreamsVerifierProxy() external view returns (IVerifierProxy streamsVerifierProxy) {
    return i_streamsVerifierProxy;
  }

  /// @notice Getter function to retrieve the list of allowlisted assets.
  /// @return allowlistedAssets List of allowlisted assets.
  function getAllowlistedAssets() external view returns (address[] memory allowlistedAssets) {
    return s_allowlistedAssets.values();
  }

  /// @notice Getter function to retrieve feed information for a given feed ID.
  /// @param asset The address of the asset.
  /// @return feedInfo The feed information associated with the feed ID.
  function getFeedInfo(
    address asset
  ) external view returns (FeedInfo memory feedInfo) {
    return s_feedInfo[asset];
  }

  /// @notice Getter function to retrieve the asset address for a given Data Streams feed ID.
  /// @param dataStreamsFeedId The Data Streams feed ID.
  /// @return asset The address of the asset associated with the feed ID.
  function getAssetFromDataStreamsFeedId(
    bytes32 dataStreamsFeedId
  ) external view returns (address asset) {
    return s_dataStreamsFeedIdToAsset[dataStreamsFeedId];
  }

  /// @notice Getter function to retrieve the latest price and timestamp for a given asset.
  /// @param asset The address of the asset.
  /// @return price The latest price of the asset, scaled to 18 decimals.
  /// @return updatedAt The timestamp of the latest price update.
  /// @return isValid Whether the returned price is valid or not (non-zero and not stale).
  function getAssetPrice(
    address asset
  ) external view returns (uint256 price, uint256 updatedAt, bool isValid) {
    return _getAssetPrice(asset, false);
  }

  /// @notice Internal function to retrieve the latest price and timestamp for a given asset.
  /// @dev This function is virtual as some additional checks may be warranted on certain chains, e.g.
  /// sequencer uptime checks on L2s.
  /// @dev The function prioritizes the Data Streams price, but if it is stale and a Chainlink data feed is configured,
  /// it will return the most recent price between the Data Streams report and the data feed, scaled to 18 decimals.
  /// @dev Precondition: if `withValidation` is enabled, the scaled price must be non-zero and must not be stale.
  /// @param asset The address of the asset.
  /// @param withValidation Whether to perform price validation or not (non-zero answer and staleness).
  /// @return price The latest price of the asset, scaled to 18 decimals.
  /// @return updatedAt The timestamp of the latest price update.
  /// @return isValid Whether the returned price is valid or not (non-zero and not stale).
  function _getAssetPrice(  //@audit-info এই asset-এর latest USD price খুঁজে বের করো (safe কিনা check করে)”
    address asset,
    bool withValidation
  ) internal view virtual returns (uint256 price, uint256 updatedAt, bool isValid) {  //@audit-info price → asset এর USD price  ,,updatedAt → price কখন update হয়েছে  ,, isValid → price valid কিনা
    DataStreamsPriceInfo memory priceInfo = s_dataStreamsPrice[asset];
    FeedInfo memory feedInfo = s_feedInfo[asset];
    uint256 minTimestamp = block.timestamp - feedInfo.stalenessThreshold;

    // Prioritize Data Streams price.
    price = priceInfo.usdPrice;
    updatedAt = priceInfo.timestamp;

    // If the Data Streams price is stale and a Data Feed is configured, fetch the Data Feed price
    if (updatedAt < minTimestamp && feedInfo.usdDataFeed != AggregatorV3Interface(address(0))) {
      (, int256 answer,, uint256 dataFeedUpdatedAt,) = feedInfo.usdDataFeed.latestRoundData();

      // Use the most recent timestamp between the Data Streams price and the Data Feed price for validation and
      // return values.
      if (updatedAt < dataFeedUpdatedAt) {
        updatedAt = dataFeedUpdatedAt;
        price = answer.toUint256();

        uint8 decimals = feedInfo.usdDataFeed.decimals();

        if (decimals < PRICE_DECIMALS) {
          price = (price * 10 ** (PRICE_DECIMALS - decimals));
        } else if (decimals > PRICE_DECIMALS) {
          price = (price / 10 ** (decimals - PRICE_DECIMALS));
        }
      }
    }

    bool isZero = price == 0;
    bool isStale = updatedAt < minTimestamp;
    isValid = !isZero && !isStale;

    // Perform price validation if enabled.
    if (withValidation) {
      if (isZero) {
        revert Errors.ZeroFeedData();
      }
      if (isStale) {
        revert Errors.StaleFeedData();
      }
    }

    return (price, updatedAt, isValid);
  }

  /// @inheritdoc IERC165
  function supportsInterface(
    bytes4 interfaceId
  ) public view virtual override(PausableWithAccessControl) returns (bool) {
    return (PausableWithAccessControl.supportsInterface(interfaceId) || interfaceId == type(IPriceManager).interfaceId);
  }
}
