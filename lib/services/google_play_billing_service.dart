import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'entitlement_service.dart';
import 'user_profile_store.dart';

/// Google Play Billing — one Oracle Pro monthly subscription (Android only).
///
/// Oracle Pro maps to the internal `Expert` tier (full access). The legacy
/// `premium_monthly` / `expert_monthly` SKUs stay recognised so early
/// subscribers restore correctly, but they are no longer offered for purchase.
abstract final class GooglePlayBillingService {
  static const proProductId = 'oracle_pro_monthly';

  /// Legacy SKUs — restore only.
  static const premiumProductId = 'premium_monthly';
  static const expertProductId = 'expert_monthly';

  static const Set<String> productIds = {proProductId, premiumProductId, expertProductId};

  static const _planKey = 'subscription_plan';
  static const _activeProductStorageKey = 'google_play_active_product_id';

  static final InAppPurchase _iap = InAppPurchase.instance;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  /// Base-plan row per product (its price is the recurring price).
  static final Map<String, ProductDetails> _products = {};
  /// Free-trial offer rows. Play only returns offers this account is eligible for.
  static final Map<String, GooglePlayProductDetails> _trialOffers = {};

  static bool _initialized = false;
  static bool _storeAvailable = false;

  static void Function(BillingPurchaseEvent event)? onPurchaseEvent;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isStoreAvailable => _storeAvailable;

  static ProductDetails? productDetails(String productId) => _products[productId];

  /// Fallback label when Play Catalog is offline — must match the Console list price.
  static const fallbackProPrice = r'$49.99';

  /// Live Google Play localized price for Oracle Pro, else Console-matching fallback.
  static String get proDisplayPrice {
    final live = _products[proProductId]?.price.trim();
    if (live != null && live.isNotEmpty) return live;
    return fallbackProPrice;
  }

  /// Length of the Oracle Pro free trial this account can still claim, else null.
  static int? get proTrialDays {
    final trial = _trialOffers[proProductId];
    final offer = trial == null ? null : _offerOf(trial);
    if (offer == null) return null;
    final phase = offer.pricingPhases.first;
    final days = _periodDays(phase.billingPeriod);
    if (days == null) return null;
    return days * (phase.billingCycleCount < 1 ? 1 : phase.billingCycleCount);
  }

  static SubscriptionOfferDetailsWrapper? _offerOf(ProductDetails product) {
    if (product is! GooglePlayProductDetails) return null;
    final index = product.subscriptionIndex;
    final offers = product.productDetails.subscriptionOfferDetails;
    if (index == null || offers == null || index >= offers.length) return null;
    return offers[index];
  }

  static bool _isFreeTrial(SubscriptionOfferDetailsWrapper offer) =>
      offer.pricingPhases.isNotEmpty && offer.pricingPhases.first.priceAmountMicros == 0;

  /// ISO-8601 period (P7D, P1W, P1M) → days.
  static int? _periodDays(String period) {
    final match = RegExp(r'^P(\d+)([DWMY])$').firstMatch(period.trim());
    if (match == null) return null;
    final n = int.parse(match.group(1)!);
    return switch (match.group(2)) {
      'D' => n,
      'W' => n * 7,
      'M' => n * 30,
      _ => n * 365,
    };
  }

  static String? planForProductId(String? productId) {
    switch (productId) {
      case proProductId:
      case expertProductId:
        return 'Expert';
      case premiumProductId:
        return 'Premium';
      default:
        return null;
    }
  }

  /// Any paid plan name resolves to the single Oracle Pro SKU.
  static String? productIdForPlan(String plan) {
    switch (plan.trim().toLowerCase()) {
      case 'pro':
      case 'oracle pro':
      case 'expert':
      case 'top tier':
      case 'premium':
        return proProductId;
      default:
        return null;
    }
  }

  static int _tierRank(String? plan) {
    switch (plan?.trim().toLowerCase()) {
      case 'expert':
      case 'top tier':
        return 2;
      case 'premium':
        return 1;
      default:
        return 0;
    }
  }

  static Future<void> init() async {
    if (!isAndroid || _initialized) return;
    _initialized = true;

    _storeAvailable = await _iap.isAvailable();
    if (!_storeAvailable) {
      debugPrint('[GooglePlayBilling] store unavailable');
      return;
    }

    _purchaseSub ??= _iap.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (Object e) {
        debugPrint('[GooglePlayBilling] purchase stream error: $e');
        _emit(BillingPurchaseEvent.error('Purchase stream error. Try again.'));
      },
    );

    await queryProducts();
    await restorePurchases(silent: true);
  }

  static Future<void> dispose() async {
    await _purchaseSub?.cancel();
    _purchaseSub = null;
    _initialized = false;
  }

  static Future<void> queryProducts() async {
    if (!_storeAvailable) return;

    final response = await _iap.queryProductDetails(productIds);
    if (response.error != null) {
      debugPrint('[GooglePlayBilling] query error: ${response.error}');
      return;
    }
    if (response.notFoundIDs.isNotEmpty) {
      debugPrint('[GooglePlayBilling] not found: ${response.notFoundIDs}');
    }

    _products.clear();
    _trialOffers.clear();
    // Google Play returns one row per eligible offer: the base plan plus any trial / promo offers.
    for (final product in response.productDetails) {
      final offer = _offerOf(product);
      if (offer != null && product is GooglePlayProductDetails && _isFreeTrial(offer)) {
        _trialOffers.putIfAbsent(product.id, () => product);
      } else if (offer != null && offer.offerId == null) {
        _products[product.id] = product;
      } else {
        _products.putIfAbsent(product.id, () => product);
      }
    }
    debugPrint('[GooglePlayBilling] products=${_products.keys} trials=${_trialOffers.keys}');
  }

  static Future<bool> purchase(String productId) async {
    if (!_storeAvailable) return false;
    if (!productIds.contains(productId)) return false;

    if (!_products.containsKey(productId)) {
      await queryProducts();
    }

    final product = _trialOffers[productId] ?? _products[productId];
    if (product == null) {
      _emit(BillingPurchaseEvent.error('Subscription not found in Google Play.'));
      return false;
    }

    _emit(BillingPurchaseEvent.pending(productId));

    final PurchaseParam param = product is GooglePlayProductDetails
        ? GooglePlayPurchaseParam(productDetails: product)
        : PurchaseParam(productDetails: product);

    try {
      return await _iap.buyNonConsumable(purchaseParam: param);
    } catch (e) {
      debugPrint('[GooglePlayBilling] buy failed: $e');
      _emit(BillingPurchaseEvent.error('Could not start Google Play purchase.'));
      return false;
    }
  }

  static Future<void> restorePurchases({bool silent = false}) async {
    if (!_storeAvailable) {
      if (!silent) {
        _emit(BillingPurchaseEvent.error('Google Play Billing is unavailable.'));
      }
      return;
    }
    if (!silent) _emit(BillingPurchaseEvent.restoring());
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('[GooglePlayBilling] restore failed: $e');
      if (!silent) {
        _emit(BillingPurchaseEvent.error('Restore failed. Try again.'));
      }
    }
  }

  static Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    var restoredAny = false;

    for (final purchase in purchases) {
      if (!productIds.contains(purchase.productID)) continue;

      switch (purchase.status) {
        case PurchaseStatus.pending:
          _emit(BillingPurchaseEvent.pending(purchase.productID));
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          restoredAny = purchase.status == PurchaseStatus.restored;
          unawaited(
            EntitlementService.verifyPurchase(
              productId: purchase.productID,
              purchaseToken: purchase.verificationData.serverVerificationData,
            ),
          );
          final plan = await _applyPurchase(purchase);
          if (plan != null) {
            _emit(BillingPurchaseEvent.success(plan));
          }
          await _completeIfNeeded(purchase);
          break;
        case PurchaseStatus.error:
          _emit(
            BillingPurchaseEvent.error(
              purchase.error?.message ?? 'Purchase failed.',
            ),
          );
          await _completeIfNeeded(purchase);
          break;
        case PurchaseStatus.canceled:
          _emit(BillingPurchaseEvent.canceled());
          await _completeIfNeeded(purchase);
          break;
      }
    }

    if (restoredAny) {
      _emit(BillingPurchaseEvent.restoreFinished(found: true));
    }
  }

  static Future<String?> _applyPurchase(PurchaseDetails purchase) async {
    final plan = planForProductId(purchase.productID);
    if (plan == null) return null;

    await UserProfileStore.load();
    final current = UserProfileStore.tier;
    if (_tierRank(plan) >= _tierRank(current)) {
      await _persistSubscription(plan: plan, productId: purchase.productID);
    }
    return plan;
  }

  static Future<void> _persistSubscription({
    required String plan,
    required String productId,
  }) async {
    final prefsPlan = plan.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_planKey, prefsPlan);
    await UserProfileStore.saveTier(prefsPlan);
    await _storage.write(key: _activeProductStorageKey, value: productId);
    debugPrint('[GooglePlayBilling] active plan=$prefsPlan product=$productId');
  }

  static Future<void> _completeIfNeeded(PurchaseDetails purchase) async {
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  static void _emit(BillingPurchaseEvent event) {
    onPurchaseEvent?.call(event);
  }
}

enum BillingPurchaseEventType {
  pending,
  success,
  error,
  canceled,
  restoring,
  restoreFinished,
}

class BillingPurchaseEvent {
  final BillingPurchaseEventType type;
  final String? productId;
  final String? plan;
  final String? message;
  final bool restoreFound;

  const BillingPurchaseEvent._({
    required this.type,
    this.productId,
    this.plan,
    this.message,
    this.restoreFound = false,
  });

  factory BillingPurchaseEvent.pending(String productId) => BillingPurchaseEvent._(
        type: BillingPurchaseEventType.pending,
        productId: productId,
      );

  factory BillingPurchaseEvent.success(String plan) => BillingPurchaseEvent._(
        type: BillingPurchaseEventType.success,
        plan: plan,
      );

  factory BillingPurchaseEvent.error(String message) => BillingPurchaseEvent._(
        type: BillingPurchaseEventType.error,
        message: message,
      );

  factory BillingPurchaseEvent.canceled() => const BillingPurchaseEvent._(
        type: BillingPurchaseEventType.canceled,
      );

  factory BillingPurchaseEvent.restoring() => const BillingPurchaseEvent._(
        type: BillingPurchaseEventType.restoring,
      );

  factory BillingPurchaseEvent.restoreFinished({required bool found}) =>
      BillingPurchaseEvent._(
        type: BillingPurchaseEventType.restoreFinished,
        restoreFound: found,
      );
}
