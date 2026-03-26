// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {IAuctionCallback} from "src/interfaces/IAuctionCallback.sol";
import {IBaseAuction} from "src/interfaces/IBaseAuction.sol";
import {IFeeAggregator} from "src/interfaces/IFeeAggregator.sol";

import {Caller} from "src/Caller.sol";
import {PriceManager} from "src/PriceManager.sol";
import {Common} from "src/libraries/Common.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Roles} from "src/libraries/Roles.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

abstract contract BaseAuction is PriceManager, ITypeAndVersion, Caller, IBaseAuction {
  using EnumerableSet for EnumerableSet.AddressSet;
  using FixedPointMathLib for uint256;
  using SafeERC20 for IERC20;

  /// @notice This event is emitted when the asset out address is set.
  /// @param assetOut The address of the asset out.
  event AssetOutSet(address indexed assetOut);  //@audit-info Auction-এ কোন token দিয়ে pay করতে হবে”,, Now সবাই জানে → bid করতে LINK লাগবে
  /// @notice This event is emitted when the asset out receiver address is set.
  /// @param assetOutReceiver The address of the asset out receiver.
  event AssetOutReceiverSet(address indexed assetOutReceiver);  //@audit-info “Collected LINK কোথায় যাবে”
  /// @notice This event is emitted when the parameters of an asset are updated.
  /// @param asset The address of the asset.
  /// @param params The updated asset parameters.
  event AssetParamsUpdated(address indexed asset, AssetParams params);  //@audit-info এই asset-এর auction rules update হলো”
  /// @notice This event is emitted when the parameters of an asset are removed.
  /// @param asset The address of the asset.
  event AssetParamsRemoved(address indexed asset);  //@audit-info এই asset আর auction-এ নেই” ,,এখন USDC আর auction হবে না
  /// @notice This event is emitted when a new fee aggregator receiver is set
  /// @param feeAggregator The address of the fee aggregator
  event FeeAggregatorSet(address indexed feeAggregator);//@audit-info new aggregator = FeeVault
  /// @notice This event is emitted when the minimum bid USD value is set.
  /// @param minBidUsdValue The minimum bid USD value in 18 decimals.
  event MinBidUsdValueSet(uint88 indexed minBidUsdValue);  //@audit-info “Minimum bid কত USD হতে হবে”
  /// @notice This event is emitted when the maximum discount basis points is set.
  /// @param minPriceMultiplier The maximum discount basis points.
  event MinPriceMultiplierSet(uint64 indexed minPriceMultiplier);  //@audit-info Maximum discount limit ,,min multiplier = 0.98 (2% discount max)
  /// @notice This event is emitted when an auction is started for an asset.
  /// @param asset The address of the asset for which the auction is started.
  event AuctionStarted(address indexed asset);  //@audit-info AuctionStarted(USDC),,এখন users bid করতে পারবে
  /// @notice This event is emitted when an auction is ended for an asset.
  /// @param asset The address of the asset for which the auction is ended.
  event AuctionEnded(address indexed asset);
  /// @notice This event is emitted when an auction is partially settled for an asset.
  /// @param bidder The address of the auction bidder.
  /// @param assetIn The address of the asset being auctioned.
  /// @param amountIn The amount of asset being auctioned.
  /// @param amountOut The amount of asset out received.
  event AuctionBidSettled(address indexed bidder, address indexed assetIn, uint256 amountIn, uint256 amountOut);  //@audit-info User:,,100 USDC নেয়,,10 LINK pay করে,,  AuctionBidSettled(user, USDC, 100, 10) ,,Full trade record হয়ে গেল

  /// @notice This error is thrown when trying to access asset parameters that are not set.
  /// @param asset The asset with unset parameters.
  error AssetParamsNotSet(address asset);//@audit-info “Asset config নাই”
  /// @notice This error is thrown when trying to set an ending price multiplier lower than the minPriceMultiplier.
  /// @param asset The asset with invalid decay rate.
  /// @param endingPriceMultiplier The ending price multiplier.
  /// @param minPriceMultiplier The price multiplier lower bound.
  error InvalidEndingPriceMultiplier(address asset, uint256 endingPriceMultiplier, uint64 minPriceMultiplier);  //@audit-info শেষ price limit খুব low (too much discount)”
  /// @notice This error is thrown when the starting price multiplier is lower than the ending price multiplier.
  /// @param asset The asset with invalid price multipliers.
  /// @param startingPriceMultiplier The starting price multiplier.
  /// @param endingPriceMultiplier The ending price multiplier.
  error StartingPriceMultiplierLowerThanEndingPriceMultiplier(  //@audit-info Start = 0.9,, End = 1.0 ❌,,price তো কমার কথা, বাড়ার না
    address asset, uint256 startingPriceMultiplier, uint256 endingPriceMultiplier
  );
  /// @notice This error is thrown when the provided asset decimals do not match the actual asset decimals.
  /// @param asset The address of the asset.
  /// @param decimals The provided asset decimals.
  /// @param expectedDecimals The actual asset decimals.
  error InvalidAssetDecimals(address asset, uint8 decimals, uint8 expectedDecimals);  //@audit-info Wrong decimals দিয়েছো
  /// @notice This error is thrown when trying to bid a non live auction (ended, not started or non allowlisted).
  /// @param asset The asset of the invalid auction.
  error InvalidAuction(address asset);  //@audit-info “Auction valid না”
  /// @notice This error is thrown when trying to update auction sensitive configs during live auctions.
  error LiveAuction();  //@audit-info Auction চলছে → change allowed না”
  /// @notice This error is thrown when the bid USD value is below the minimum auction size.
  /// @param bidUsdValue The bid USD value.
  /// @param minAuctionSizeUsd The minimum auction size in USD.
  error BidValueTooLow(uint256 bidUsdValue, uint256 minAuctionSizeUsd);//@audit-info Bid value below minimum USD threshold; Example: min=$100, user bids $20 → revert
  /// @notice This error is thrown when the bid amount is higher than the available amount in the auction.
  /// @param bidAmount The bid amount.
  /// @param availableAmount The available amount in the auction.
  error BidAmountTooHigh(uint256 bidAmount, uint256 availableAmount);//@audit-info Requested amount exceeds available balance; Example: available=100 USDC, user asks 200 → revert
  /// @notice This error is thrown when trying to call performUpkeep while the asset out parameters are missing.
  error MissingAssetOutParams();//@audit-info Payment token (assetOut) not configured → auction cannot function; Example: LINK params missing → performUpkeep fails
  /// @notice This error is thrown when trying to force start an auction with an amount below the minimum auction size.
  /// @param amountUsdValue The amount USD value.
  /// @param minAuctionSizeUsd The minimum auction size in USD.
  error AmountBelowMinAuctionSize(uint256 amountUsdValue, uint256 minAuctionSizeUsd);//@audit-info Auction start করার amount খুব ছোট; Example: min=$1000 কিন্তু আছে $100 → auction start হবে না

  // @notice Parameters to initialize the contract in the constructor.
  // solhint-disable-next-line gas-struct-packing
  struct ConstructorParams {
    address admin; // ────────────────────────────────────╮
    // The initial contract admin.
    uint48 adminRoleTransferDelay; // ────────────────────╯ The min seconds
    // before the admin address can be transferred.
    uint64 minPriceMultiplier; // ────────────────────────╮   //@audit-info price কত কমতে পারবে (max discount limit)
    // auction price multiplier lower bound in basis points
    //                                                    │ used for input validation of all assets configured in the
    //                                                    │ contract.
    address verifierProxy; // ────────────────────────────╯   //@audit-info Price oracle contract address.
    // The address of the Data Streams VerifierProxy contract.
    uint88 minBidUsdValue; // ────────────────────────────╮
    // The minimum bid USD value in 18 decimals.
    address linkToken; // ────────────────────────────────╯
    // The address of the LINK token contract.
    address assetOut; //                                    The asset out of all the auctions.//@audit-info Token users pay with link.,,The main auction payment token.
    address assetOutReceiver; //                            The asset out receiver.//@audit-info  Where the collected payment go,, Treasury / vault address.
    address feeAggregator; //                               The fee aggregator.//@audit-info Contract where auction fees are collected.
    PriceManager.ApplyFeedInfoUpdateParams[] feedInfos; //  The initial feed info list.  //@audit-info Defines how prices are fetched for each asset.
  }

  /// @notice The auction parameters of an asset.
  /// @dev The decay rate per second is applied linearly to the starting price multiplier.
  /// @dev Asset parameters should also be configured for the asset out. Although it is not auctioned, the min auction
  /// size and decimals fields are still used.
  /// Example:
  ///   - startingPriceMultiplier = 1.1e18 (10% premium)
  ///   - endingPriceMultiplier = 0.98e18 (2% discount)
  ///   - auctionDuration = 3600 (1 hour)
  ///   - decayRatePerSecond = (1.1e18 - 0.98e18) / 3600 = 33333333333333 (rounded down to avoid higher
  ///     discount than 2%)
  struct AssetParams {
    uint96 minAuctionSizeUsd; // ───────╮ The minimum swap size expressed in USD feed decimals//@audit-info USD তে ন্যূনতম অকশন সাইজ।.
    uint64 startingPriceMultiplier; //  │ The starting price multiplier with 18 decimals precision.//@audit-info সাধারণত >1 → প্রাথমিকভাবে প্রিমিয়াম দেয়।
    uint64 endingPriceMultiplier; //    │ The ending price multiplier with 18 decimals precision.  //@audit-info অকশনের শেষ মূল্য,,  সাধারণত <1 → সময়ের সাথে ডিসকাউন্ট প্রয়োগ করে।
    uint24 auctionDuration; //          │ The duration of the auction in seconds.  //@audit-info অকশন কতক্ষণ চলবে (সেকেন্ডে),,  উদাহরণ: 3600 = 1 ঘন্টা।
    uint8 decimals; //  ────────────────╯ The asset decimals.
  }

  /// @notice The parameters for adding or updating asset parameters.
  struct ApplyAssetParamsUpdate {
    address asset; // The address of the asset.
    AssetParams params; // The asset parameters.//@audit-info যেমন minAuctionSizeUsd, starting/endingMultiplier, duration, decimals ইত্যাদি।
  }

  /// @inheritdoc ITypeAndVersion
  string public constant override typeAndVersion = "Auction 1.0.0-dev";

  /// @notice The auction price multiplier lower bound in 18 decimals used for input validation of all assets configured
  /// in the contract - e.g. 0.98e18 represents a maximum discount of 2%.
  uint64 internal immutable i_minPriceMultiplier;//@audit-info অকশন প্রাইসের লোয়ার বাউন্ড।

  /// @notice Reentrant flag.
  bool internal s_entered;
  /// @notice The minimum bid USD value in 18 decimals.
  uint88 internal s_minBidUsdValue;
  /// @notice The asset out of all the auctions.
  address internal s_assetOut;  //@audit-info user যা দেয় (যেমন: LINK),,  //@audit-info Auction sells → USDC,, User pays → LINK
  /// @notice The receiver of to tokens.
  address internal s_assetOutReceiver; 
  /// @notice The fee aggregator
  IFeeAggregator internal s_feeAggregator;

  /// @notice Mapping from `from` token to its struct.
  mapping(address asset => AssetParams params) internal s_assetParams;//@audit-info 👉 from token (অ্যাসেট) থেকে তার AssetParams পেতে।
  /// @notice Mapping from `from` token to the auction start timestamp.
  mapping(address asset => uint256 auctionStart) internal s_auctionStarts;  //@audit-info 👉 কবে অকশন শুরু হয়েছে তা ট্র্যাক করতে।

  modifier whenAssetOutConfigured() {
    if (s_assetParams[s_assetOut].decimals == 0) {  //@audit-info যদি decimals == 0 → MissingAssetOutParams() রিভার্ট।
      revert MissingAssetOutParams();
    }
    _;
  }

  constructor(
    ConstructorParams memory params
  )
    PriceManager(params.adminRoleTransferDelay, params.admin, params.verifierProxy, params.linkToken, params.feedInfos)  //@audit-info PriceManager(...),, Parent contract setup
  { 
    if (params.assetOut == address(0) || params.assetOutReceiver == address(0)) {
      revert Errors.InvalidZeroAddress();
    }

    _setMinBidUsdValue(params.minBidUsdValue);//@audit-info minBidUsdValue = $100
    _setAssetOut(params.assetOut);  //@audit-info LINK দিয়ে pay করবে
    _setAssetOutReceiver(params.assetOutReceiver);  //@audit-info সব collected LINK যাবে:
    _setFeeAggregator(params.feeAggregator);
 
    if (params.minPriceMultiplier == 0) {
      revert Errors.InvalidZeroValue();
    }

    i_minPriceMultiplier = params.minPriceMultiplier;

    emit MinPriceMultiplierSet(params.minPriceMultiplier);
  }
  
    /// @inheritdoc IBaseAuction
  /// @dev This function checks for eligible assets to start auctions and ended auctions to be closed.
  /// @dev precondition - The contract must not be paused.
  /// @dev precondition - The asset out must be configured.
  /// For an auction to be considered eligible to start, the following conditions must be met:
  ///   1) The asset out price must be valid (not stale and not zero).
  ///   2) There is no live auction for the asset.
  ///   3) The asset price is valid (not stale and not zero).
  ///   4) The total USD value of the asset (in both the fee aggregator and the auction contract) is above the minimum
  ///      auction size.
  /// For an auction to be considered ended, either of the following conditions must be met:
  ///   - The auction duration has elapsed since the auction start time.
  ///   - The total USD value of the asset remaining in the auction contract is below the minimum auction size. This is
  ///     to guard against dust attacks.
  function checkUpkeep(
    bytes calldata
  ) external view whenNotPaused whenAssetOutConfigured returns (bool upkeepNeeded, bytes memory performData) {
    address feeAggregator = address(s_feeAggregator);
    address[] memory auctions = s_allowlistedAssets.values();  //@audit-info এখন auctions array = [USDC_address, WETH_address, DAI_address]
    Common.AssetAmount[] memory eligibleAssets = new Common.AssetAmount[](auctions.length);//@audit-info AssetAmount struct use করার syntax  ,,অর্থ: eligibleAssets = AssetAmount struct array, memory এ রাখা হয়েছে, size = auctions.length
    address[] memory endedAuctions = new address[](auctions.length);//@audit-info এই array endedAuctions হলো যেসব asset এর auction শেষ হয়ে গেছে বা close করা যাবে, তাদের জন্য।

    uint256 eligibleAssetsIdx;  //@audit-info কতগুলো asset auction শুরু করতে যোগ্য সেটার counter
    uint256 endedAuctionsIdx;  //@audit-info কতগুলো auction শেষ হয়েছে সেটার counter
    bool isAssetOutPriceValid;  //@audit-info মূল auction token (assetOut) এর price valid কিনা check করার জন্য

    for (uint256 i; i < auctions.length; ++i) {
      address asset = auctions[i];

      AssetParams memory assetParams = s_assetParams[asset];  //@audit-info প্রতিটা asset এর configuration load করা হচ্ছে।

      // Skip assets without configured params.
      if (assetParams.decimals == 0) {  //@audit-info যদি asset এর params configure না করা হয় → skip।
        continue;  //@audit-info এই asset ignore করো, আমরা auction এর জন্য এটি use করতে পারব না।
      }

      (uint256 assetPrice,, bool isPriceValid) = _getAssetPrice(asset, false);  //@audit-info false মানে,, ➡️ “আমাকে শুধু info দাও, error throw করো না”

      if (asset == s_assetOut) {  //@audit-info এই asset কি main payment token?”
        isAssetOutPriceValid = isPriceValid;  //@audit-info তখন store করবে:LINK token-এর price valid কিনা,,LINK price valid = false 
      }

      // 1) Check for live or ended auctions.
      uint256 auctionStart = s_auctionStarts[asset]; //@audit-info 👉কবে অকশন শুরু হয়েছে তা store করতে।
      if (auctionStart != 0) {//@audit-info → মানে: এই asset এর auction আগে থেকেই শুরু হয়ে গেছে।
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));  //@audit-info assetBalance ,,contract এ থাকা USDC , assetBalance =100 USDC 
        uint256 assetBalanceUsdValue = (assetBalance * assetPrice) / (10 ** assetParams.decimals);//@audit-info “এই লাইনে contract এ থাকা token এর মোট value USD-এ convert করা হচ্ছে”  ,, $100 (18 decimals format)
        if (
          auctionStart + assetParams.auctionDuration < block.timestamp  //@audit-info Auction start = 10:00 AM ,,Duration = 1 hour ,, Now = 11:10 AM ,,➡️ 11:00 এর পরে → auction শেষ ❌
            || (isPriceValid && assetBalanceUsdValue < assetParams.minAuctionSizeUsd)  //? @audit-info  price ঠিক আছে (not stale, not zero) ,,auction-এ এখন যত asset বাকি আছে → সেটা minimum requirement এর নিচে
        ) {
          endedAuctions[endedAuctionsIdx++] = asset;  //@audit-info endedAuctions[idx] = asset; ,,idx = idx + 1; ,, current index এ store করো, তারপর index +1 করো”
        }
      } else if (isPriceValid) {
        // 2) Get the current asset value in USD available for auction.
        uint256 availableBalance = IERC20(asset).balanceOf(feeAggregator);//@audit-info availableBalance = 1000
        uint256 availableAssetUsdValue = (availableBalance * assetPrice) / (10 ** assetParams.decimals);  //@audit-info এখানে convert হচ্ছে → USD value ,, 1000 × $1 = $1000

        // 3) Auction asset if the asset's current USD balance is above the minimum auction size.
        if (availableAssetUsdValue >= assetParams.minAuctionSizeUsd) {  //@audit-info $1000 ≥ $100 ✅
          // We only pass in the fee aggregator balance as the amount since its sole purpose is to pull funds from the
          // fee aggregator.
          eligibleAssets[eligibleAssetsIdx++] = Common.AssetAmount({asset: asset, amount: availableBalance});  //@audit-info eligibleAssets[0] = {asset: USDC, amount: 1000} ,, eligibleAssetsIdx = 1
        }
      }
    }

    // If the asset out price is not valid, we s`hould not start any auctions even if there are eligible assets as bids
    // would revert.
    if (!isAssetOutPriceValid) {
      eligibleAssetsIdx = 0;  //@audit-info eligibleAssets = [{USDC, 1000}] ,, LINK price = INVALID ❌ ,, eligibleAssetsIdx = 0  ,, → eligibleAssets = empty
    }
    if (eligibleAssetsIdx < auctions.length) {  //@audit-info 1 < 3 → TRUE ✅
      assembly {  //@audit-info “Solidity bypass করে সরাসরি EVM (low-level) code লেখা”
        // update eligibleassets length.
        mstore(eligibleAssets, eligibleAssetsIdx)  //@audit-info  mstore(weth, 1)  ,, 2 < 2 → FALSE ❌  ,,mstore call হবে না ,,কারণ already perfect size
          //@audit-info “যতজন আসলে আছে, array-কে তত বড় দেখাও”
      }
    }
    if (endedAuctionsIdx < auctions.length) {  //@audit-info 1 < 3 → TRUE ✅  
      assembly {  //@audit-info if (actual < max) ,,,→ extra empty slot hide করো
        // update endedAuctionsIdx length.
        mstore(endedAuctions, endedAuctionsIdx)//@audit-info length = 1 ,, [WETH]
      }
    }

    // Using if/else here to avoid abi.encoding empty bytes when idx = 0.
    if (eligibleAssetsIdx > 0 || endedAuctionsIdx > 0) {  //@audit-info eligibleAssetsIdx = 2   // USDC, WETH ,,endedAuctionsIdx = 1    // DAI  ,,2 > 0 ✅ বা 1 > 0 ✅ → true
      upkeepNeeded = true;
      performData = abi.encode(eligibleAssets, endedAuctions);//@audit-info [USDC, WETH] ,, [DAI]
 
    }

    return (upkeepNeeded, performData);
  }


  /// @inheritdoc IBaseAuction
  /// @dev precondition - The contract must not be paused.
  /// @dev precondition - The asset out must be configured.
  /// @dev precondition - The caller must have the AUCTION_WORKER_ROLE.
  /// @dev precondition - When starting auctions, the asset out price must be valid.
  /// @dev precondition - When starting auctions, there must not be a live auction for the asset.
  /// @dev precondition - Eligible assets must be configured.
  /// @dev precondition - Eligible assets amounts USD values must be above the minimum auction size.
  /// @dev precondition - Ended auctions must not be the asset out.
  function performUpkeep(//@audit-info execution engine 🔥
    bytes calldata performData 
  ) external whenNotPaused whenAssetOutConfigured onlyRole(Roles.AUCTION_WORKER_ROLE) {
    (Common.AssetAmount[] memory eligibleAssets, address[] memory endedAuctions) =  //@audit-info checkUpkeep() already decide করে দিয়েছে: ,, eligibleAssets = [USDC: 1000]  ,, endedAuctions = [DAI]
      abi.decode(performData, (Common.AssetAmount[], address[]));  //@audit-info Common.AssetAmount = (USDC, 1000)

    // We should never pass a list of eligible assets with a non valid asset out price.
    uint256 assetOutPrice;  //@audit-info এখানে শুধু variable declare করা হয়েছে  ,,assetOutPrice = empty
    address assetOut = s_assetOut; //link 
    if (eligibleAssets.length > 0) { 
      (assetOutPrice,,) = _getAssetPrice(assetOut, true);//@audit-info “assetOut এর validated (safe) price নিয়ে আসো — invalid হলে revert করো” --valid price= true
    }

    bool hasFeeAggregator = address(s_feeAggregator) != address(this);  //@audit-info hasFeeAggregator = true

    if (hasFeeAggregator && eligibleAssets.length > 0) {
      s_feeAggregator.transferForSwap(address(this), eligibleAssets);  //@audit-info Auction Contract → FeeAggregator call করছে --to = address(this)--assetAmounts = eligibleAssets
    }

    for (uint256 i; i < eligibleAssets.length; ++i) {
      address asset = eligibleAssets[i].asset;  //@audit-info eligibleAssets[0].asset → USDC --eligibleAssets[1].asset → DAI

      if (s_auctionStarts[asset] != 0) {
        revert LiveAuction();
      }

      AssetParams storage assetParams = s_assetParams[asset];
      uint8 assetDecimals = assetParams.decimals;

      if (assetDecimals == 0) {
        revert AssetParamsNotSet(asset);
      }

      uint256 assetPrice;
      if (asset == assetOut) {
        assetPrice = assetOutPrice;
      } else {
        (assetPrice,,) = _getAssetPrice(asset, true);
      }
      uint256 availableAssetUsdValue = (eligibleAssets[i].amount * assetPrice) / (10 ** assetDecimals);

      if (availableAssetUsdValue < assetParams.minAuctionSizeUsd) {
        revert AmountBelowMinAuctionSize(availableAssetUsdValue, assetParams.minAuctionSizeUsd);
      }

      if (asset == s_assetOut) {
        IERC20(asset).safeTransfer(s_assetOutReceiver, IERC20(asset).balanceOf(address(this)));
      } else {
        s_auctionStarts[asset] = block.timestamp;
        _onAuctionStart(asset);
        emit AuctionStarted(asset);
      }
    }

    for (uint256 i; i < endedAuctions.length; ++i) {
      address asset = endedAuctions[i];

      if (s_auctionStarts[asset] == 0) {
        revert InvalidAuction(asset);
      }

      _onAuctionEnd(endedAuctions[i], hasFeeAggregator);
      delete s_auctionStarts[asset];
      emit AuctionEnded(asset);
    }
  }

  /// @dev This function is virtual for potential integration e.g. approving tokens to external contracts not solving
  /// through the bid() function.
  /// @param asset The address of the asset being auctioned.
  function _onAuctionStart(
    address asset
  ) internal virtual {}

  /// @dev Ends an auction for a specific asset by transferring any remaining asset balance to the fee aggregator and
  /// transferring all asset out balance to the asset out receiver.
  /// @param asset The address of the asset being auctioned.
  /// @param hasFeeAggregator Whether a fee aggregator is configured.
  function _onAuctionEnd(
    address asset,
    bool hasFeeAggregator
  ) internal virtual {
    if (hasFeeAggregator) {
      uint256 assetBalance = IERC20(asset).balanceOf(address(this));
      if (assetBalance > 0) {
        IERC20(asset).safeTransfer(address(s_feeAggregator), assetBalance);
      }
    }
    uint256 assetOutBalance = IERC20(s_assetOut).balanceOf(address(this));
    if (assetOutBalance > 0) {
      IERC20(s_assetOut).safeTransfer(s_assetOutReceiver, assetOutBalance);
    }
  }

  // ================================================================================================
  // │                                    Auction Participation                                     │
  // ================================================================================================

  /// @inheritdoc IBaseAuction
  /// @dev precondition - The auction for the asset must be live (i.e. started and not ended).
  /// @dev precondition - The caller must have approved the contract to spend at least `assetOutAmount` amount of asset
  /// out.
  /// @dev precondition - The call must not be reentered.
  /// @dev precondition - The bid USD value must be above the minimum auction size.
  /// @dev precondition - The bid amount must be less than or equal to the available amount in the auction.
  function bid(
    address asset,
    uint256 amount,
    bytes calldata data
  ) external whenNotPaused {
    if (s_entered) {
      revert Errors.ReentrantCall();
    }
    s_entered = true;

    AssetParams memory assetParams = s_assetParams[asset];
    uint256 auctionStart = s_auctionStarts[asset];

    uint256 elapsedTime = block.timestamp - auctionStart;

    if (auctionStart == 0 || elapsedTime > assetParams.auctionDuration) {
      revert InvalidAuction(asset);
    }

    (uint256 assetPrice,,) = _getAssetPrice(asset, true);
    uint256 bidUsdValue = (amount * assetPrice) / (10 ** assetParams.decimals);
    uint88 minBidUsdValue = s_minBidUsdValue;

    if (bidUsdValue < minBidUsdValue) {
      revert BidValueTooLow(bidUsdValue, minBidUsdValue);
    }

    uint256 availableBalance = IERC20(asset).balanceOf(address(this));
    if (amount > availableBalance) {
      revert BidAmountTooHigh(amount, availableBalance);
    }

    uint256 assetOutAmount = _getAssetOutAmount(assetParams, assetPrice, amount, elapsedTime, true);

    IERC20(asset).safeTransfer(msg.sender, amount);

    address assetOut = s_assetOut;
    // If the caller has specified data.
    if (data.length != 0) {
      IAuctionCallback(msg.sender).auctionCallback(msg.sender, assetOut, assetOutAmount, data);
    }

    // Pull assetOut from the caller.
    IERC20(assetOut).safeTransferFrom(msg.sender, address(this), assetOutAmount);

    emit AuctionBidSettled(msg.sender, asset, amount, assetOutAmount);

    s_entered = false;
  }

  // ================================================================================================
  // │                                        Configuration                                         │
  // ================================================================================================

  /// @notice Sets the minimum bid USD value.
  /// @dev precondition - The caller must have the ASSET_ADMIN_ROLE.
  function setMinBidUsdValue(
    uint88 minBidUsdValue
  ) external onlyRole(Roles.ASSET_ADMIN_ROLE) {
    _setMinBidUsdValue(minBidUsdValue);
  }

  /// @dev precondition - The new minimum bid USD value must be greater than zero.
  /// @dev precondition - The new minimum bid USD value must be different from the already configured one.
  function _setMinBidUsdValue(//@audit-ok 
    uint88 minBidUsdValue
  ) private {
    if (minBidUsdValue == 0) {
      revert Errors.InvalidZeroValue();
    }
    if (s_minBidUsdValue == minBidUsdValue) {
      revert Errors.ValueNotUpdated();
    }
    s_minBidUsdValue = minBidUsdValue;

    emit MinBidUsdValueSet(minBidUsdValue);
  }

  /// @notice Sets the asset out address.
  /// @dev precondition - The caller must have the ASSET_ADMIN_ROLE.
  /// @param assetOut The address of the asset out.
  function setAssetOut(
    address assetOut
  ) external onlyRole(Roles.ASSET_ADMIN_ROLE) {
    _setAssetOut(assetOut);
  }

  /// @dev precondition - There must not be a live auction.
  /// @dev precondition - The asset out address must not be the zero address.
  /// @dev precondition - The new asset out address must be different from the already configured asset out.
  function _setAssetOut(
    address assetOut
  ) private {
    _whenNoLiveAuctions();//@audit-info auction চললে change allowed না”
    if (assetOut == address(0)) {
      revert Errors.InvalidZeroAddress();
    }
    address currentAssetOut = s_assetOut;
    if (currentAssetOut == assetOut) {
      revert Errors.ValueNotUpdated();
    }

    s_assetOut = assetOut;
    delete s_assetParams[currentAssetOut];

    emit AssetOutSet(assetOut);
  }

  /// @notice Sets the asset out receiver address.
  /// @dev precondition - The caller must have the DEFAULT_ADMIN_ROLE.
  /// @param assetOutReceiver The address of the asset out receiver.
  function setAssetOutReceiver(
    address assetOutReceiver
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setAssetOutReceiver(assetOutReceiver);
  }

  /// @dev precondition - There must not be a live auction.
  /// @dev precondition - The new asset out receiver address must not be the zero address.
  /// @dev precondition - The new asset out receiver address must be different from the already configured asset out
  /// receiver.
  function _setAssetOutReceiver(
    address assetOutReceiver
  ) private {
    _whenNoLiveAuctions();
    if (assetOutReceiver == address(0)) {
      revert Errors.InvalidZeroAddress();
    }
    if (s_assetOutReceiver == assetOutReceiver) {
      revert Errors.ValueNotUpdated();
    }
    s_assetOutReceiver = assetOutReceiver;

    emit AssetOutReceiverSet(assetOutReceiver);
  }

  /// @notice Sets the fee aggregator receiver.
  /// @dev precondition - The caller must have the DEFAULT_ADMIN_ROLE.
  /// @param feeAggregator The address of the fee aggregator.
  function setFeeAggregator(
    address feeAggregator
  ) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setFeeAggregator(feeAggregator);
  }

  /// @dev precondition - There must not be a live auction.
  /// @dev precondition - The new fee aggregator address must not be the zero address.
  /// @dev precondition - The new fee aggregator address must be different from the already configured fee aggregator.
  /// @dev precondition - The new fee aggregator address must implement the IFeeAggregator interface.
  function _setFeeAggregator(
    address feeAggregator
  ) private {
    _whenNoLiveAuctions();
    if (feeAggregator == address(0)) {
      revert Errors.InvalidZeroAddress();
    }
    if (address(s_feeAggregator) == feeAggregator) {
      revert Errors.ValueNotUpdated();
    }
    if (feeAggregator != address(this) && !IERC165(feeAggregator).supportsInterface(type(IFeeAggregator).interfaceId)) {
      revert Errors.InvalidFeeAggregator(feeAggregator);
    }

    s_feeAggregator = IFeeAggregator(feeAggregator);

    emit FeeAggregatorSet(feeAggregator);
  }

  /// @notice Applies asset parameters updates by adding or removing assets from the allowlist.
  /// @dev precondition - The caller must have the ASSET_ADMIN_ROLE.
  /// @param adds The list of assets to add or update along with their parameters.
  /// @param removes The list of assets to remove from the allowlist.
  function applyAssetParamsUpdates(
    ApplyAssetParamsUpdate[] calldata adds,
    address[] calldata removes
  ) external whenNotPaused onlyRole(Roles.ASSET_ADMIN_ROLE) {
    _applyAssetParamsUpdates(adds, removes);
  }

  /// @dev precondition - The adds and removes lists must not both be empty.
  /// @dev precondition - Removed assets must not have a live auction.
  /// @dev precondition - Removed assets must be have already set params.
  /// @dev precondition - Added/updated asset must be allowlisted.
  /// @dev precondition - Added/updated staleness threshold must be greater than zero.
  /// @dev precondition - Added/updated auction duration must be greater than zero.
  /// @dev precondition - Added/updated minimum auction size in USD must be greater than zero.
  /// @dev precondition - Added/updated decay rate must be valid based on auction duration and max discount.
  /// @dev precondition - Added/updated asset decimals must match the actual asset decimals.
  function _applyAssetParamsUpdates(
    ApplyAssetParamsUpdate[] calldata adds,
    address[] calldata removes
  ) private {
    if (adds.length == 0 && removes.length == 0) {
      revert Errors.EmptyList();
    }

    address assetOut = s_assetOut;

    for (uint256 i; i < removes.length; ++i) {
      address asset = removes[i];

      if ((asset == assetOut && _liveAuctionExists()) || s_auctionStarts[asset] != 0) {
        revert LiveAuction();
      }

      if (s_assetParams[asset].decimals == 0) {
        revert AssetParamsNotSet(asset);
      }

      delete s_assetParams[asset];

      emit AssetParamsRemoved(asset);
    }

    for (uint256 i; i < adds.length; ++i) {
      AssetParams memory assetParams = adds[i].params;
      address asset = adds[i].asset;

      if ((asset == assetOut && _liveAuctionExists()) || s_auctionStarts[asset] != 0) {
        revert LiveAuction();
      }

      if (!s_allowlistedAssets.contains(asset)) {
        revert Errors.AssetNotAllowlisted(asset);
      }

      uint8 assetDecimals = IERC20Metadata(asset).decimals();

      if (assetParams.decimals != assetDecimals) {
        revert InvalidAssetDecimals(asset, assetParams.decimals, assetDecimals);
      }
      if (assetParams.minAuctionSizeUsd == 0) {
        revert Errors.InvalidZeroValue();
      }

      // The asset out is also configured but it only requires the min auction size to avoid dust attacks.
      if (asset != s_assetOut) {
        if (assetParams.auctionDuration == 0) {
          revert Errors.InvalidZeroValue();
        }
        if (assetParams.endingPriceMultiplier < i_minPriceMultiplier) {
          revert InvalidEndingPriceMultiplier(asset, assetParams.endingPriceMultiplier, i_minPriceMultiplier);
        }
        if (assetParams.endingPriceMultiplier > assetParams.startingPriceMultiplier) {
          revert StartingPriceMultiplierLowerThanEndingPriceMultiplier(
            asset, assetParams.startingPriceMultiplier, assetParams.endingPriceMultiplier
          );
        }
      }

      s_assetParams[asset] = assetParams;

      emit AssetParamsUpdated(asset, assetParams);
    }
  }

  /// @dev Helper function to check that there are no live auctions, used as a precondition for configuration changes
  /// that should not be applied during live auctions
  function _whenNoLiveAuctions() internal view {//@audit-ok 
    if (_liveAuctionExists()) {
      revert LiveAuction();
    }
  }

  /// @dev Helper function to check if there is at least one live auction.
  /// @return true if there is at least one live auction, false otherwise.
  function _liveAuctionExists() internal view returns (bool) {
    for (uint256 i; i < s_allowlistedAssets.length(); ++i) {
      if (s_auctionStarts[s_allowlistedAssets.at(i)] != 0) {
        return true;
      }
    }
    return false;
  }

  /// @inheritdoc PriceManager
  /// @dev precondition - If the updated feed info is for the asset out, there must not be a live auction.
  /// @dev precondition - The updated feed info must not be for an asset with a live auction.
  function _onFeedInfoUpdate(
    address asset,
    bool isRemoved
  ) internal override {
    super._onFeedInfoUpdate(asset, isRemoved);

    if ((asset == s_assetOut && _liveAuctionExists()) || s_auctionStarts[asset] != 0) {
      revert LiveAuction();
    }
  }

  // ================================================================================================
  // │                                           Getters                                            │
  // ================================================================================================

  /// @inheritdoc IBaseAuction
  function getAssetOut() external view returns (address assetOut) {
    return s_assetOut;
  }

  /// @notice Getter function to retrieve the asset out receiver address.
  /// @return assetOutReceiver The address of the asset out receiver.
  function getAssetOutReceiver() external view returns (address assetOutReceiver) {
    return s_assetOutReceiver;
  }

  /// @notice Getter function to retrieve the configured fee aggregator
  /// @return feeAggregator The configured fee aggregator
  function getFeeAggregator() external view returns (IFeeAggregator feeAggregator) {
    return s_feeAggregator;
  }

  /// @notice Getter function to retrieve an asset params.
  /// @param asset The address of the asset.
  /// @return assetParams The asset params.
  function getAssetParams(
    address asset
  ) external view returns (AssetParams memory assetParams) {
    return s_assetParams[asset];
  }

  /// @notice Getter function to retrieve the auction start timestamp and auctioned amount of an asset.
  /// @param asset The address of the asset.
  /// @return auctionStart the start timestamp of the auction.
  function getAuctionStart(
    address asset
  ) external view returns (uint256 auctionStart) {
    return s_auctionStarts[asset];
  }

  /// @notice Getter function to retrieve the maximum discount basis points.
  function getMinPriceMultiplier() external view returns (uint64) {
    return i_minPriceMultiplier;
  }

  /// @inheritdoc IBaseAuction
  /// @dev This function does not revert but will return zero instead on:
  ///   - Invalid auctions
  ///   - Stale prices
  ///   - Invalid timestamp
  /// @dev Reverts are still possible if prices fallback to data feeds and return an answer <= 0.
  function getAssetOutAmount(
    address assetIn,
    uint256 amount,
    uint256 timestamp
  ) external view returns (uint256 assetOutAmount) {
    AssetParams memory assetInParams = s_assetParams[assetIn];
    uint256 auctionStart = s_auctionStarts[assetIn];

    if (auctionStart == 0 || auctionStart + assetInParams.auctionDuration < timestamp || timestamp < auctionStart) {
      return 0;
    }

    uint256 availableBalance = IERC20(assetIn).balanceOf(address(this));
    amount = amount > availableBalance ? availableBalance : amount;

    (uint256 assetInUsdPrice,,) = _getAssetPrice(assetIn, false);

    return _getAssetOutAmount(assetInParams, assetInUsdPrice, amount, timestamp - auctionStart, false);
  }

  /// @dev Computes the current auction price for a given asset and amount at a specific timestamp.
  /// @param assetInParams The parameters of the auctioned asset.
  /// @param assetInUsdPrice The USD price of the auctioned asset.
  /// @param amountIn The amount of the asset.
  /// @param elapsedTime The elapsed time since the auction start in seconds.
  /// @param withValidation Whether to perform price validation when fetching asset prices.
  /// @return assetOutAmount The computed amountIn value in terms of assetOut after the elapsed time on the auction
  /// curve.
  function _getAssetOutAmount(
    AssetParams memory assetInParams,
    uint256 assetInUsdPrice,
    uint256 amountIn,
    uint256 elapsedTime,
    bool withValidation
  ) internal view returns (uint256 assetOutAmount) {
    // Compute auction elapsed time, bounded to auction duration.
    elapsedTime = elapsedTime > assetInParams.auctionDuration ? assetInParams.auctionDuration : elapsedTime;

    // Compute price multiplier based on linear decay with:
    //
    //                                              startingPriceMultiplier - endingPriceMultiplier
    // priceMultiplier = startingPriceMultiplier * ------------------------------------------------- * elapsedTime
    //                                                              auctionDuration
    //
    uint256 priceMultiplier = assetInParams.startingPriceMultiplier
      - uint256(assetInParams.startingPriceMultiplier - assetInParams.endingPriceMultiplier)
        .mulDiv(elapsedTime, assetInParams.auctionDuration);

    // Compute auction price in asset out.
    (uint256 assetOutUsdPrice,,) = _getAssetPrice(s_assetOut, withValidation);
    uint256 auctionUsdValue = amountIn.mulDivUp(assetInUsdPrice, 10 ** assetInParams.decimals).mulWadUp(priceMultiplier);

    // Convert USD value to asset out amount.
    return auctionUsdValue.mulDivUp(10 ** s_assetParams[s_assetOut].decimals, assetOutUsdPrice);
  }

  /// @inheritdoc IERC165
  function supportsInterface(
    bytes4 interfaceId
  ) public view override returns (bool) {
    return (super.supportsInterface(interfaceId) || interfaceId == type(IBaseAuction).interfaceId);
  }
}
  /*@audit-info 🔢 Fixed Example (সব জায়গায় একই)
Auction asset: USDC
Asset out: LINK
Total: 1000 USDC
Price:
1 USDC = $1
1 LINK = $10 */