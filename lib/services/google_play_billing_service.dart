import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'user_profile_store.dart';

/// Google Play Billing — monthly Premium / Expert subscriptions (Android only).
abstract final class GooglePlayBillingService {
  static const premiumProductId = 'premium_monthly';
  static const expertProductId = 'expert_monthly';

  static const Set<String> productIds = {premiumProductId, expertProductId};

  static const _planKey = 'subscription_plan';
  static const _activeProductStorageKey = 'google_play_active_product_id';

  static final InAppPurchase _iap = InAppPurchase.instance;

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
  static final Map<String, ProductDetails> _products = {};

  static bool _initialized = false;
  static bool _storeAvailable = false;

  static void Function(BillingPurchaseEvent event)? onPurchaseEvent;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isStoreAvailable => _storeAvailable;

  static ProductDetails? productDetails(String productId) => _products[productId];

  static String? planForProductId(String? productId) {
    switch (productId) {
      case premiumProductId:
        return 'Premium';
      case expertProductId:
        return 'Expert';
      default:
        return null;
    }
  }

  static String? productIdForPlan(String plan) {
    switch (plan.trim().toLowerCase()) {
      case 'premium':
        return premiumProductId;
      case 'expert':
        return expertProductId;
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
    for (final product in response.productDetails) {
      // Google Play may return multiple offer rows per subscription id — keep the first.
      _products.putIfAbsent(product.id, () => product);
    }
  }

  static Future<bool> purchase(String productId) async {
    if (!_storeAvailable) return false;
    if (!productIds.contains(productId)) return false;

    if (!_products.containsKey(productId)) {
      await queryProducts();
    }

    final product = _products[productId];
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
