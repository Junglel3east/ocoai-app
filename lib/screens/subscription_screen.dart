// Oracle Pro subscription page.

part of '../main.dart';

class SubscriptionPlanScreen extends StatefulWidget {
  /// Where the user came from, for paywall funnel stats.
  final String source;

  const SubscriptionPlanScreen({super.key, this.source = 'upgrade_prompt'});

  @override
  State<SubscriptionPlanScreen> createState() => _SubscriptionPlanScreenState();
}

class _SubscriptionPlanScreenState extends State<SubscriptionPlanScreen> {
  String _currentPlan = 'Free';
  String? _purchasingProductId;
  bool _isRestoring = false;

  @override
  void initState() {
    super.initState();
    GooglePlayBillingService.onPurchaseEvent = _onBillingEvent;
    _loadPlan();
    _refreshStorePrices();
  }

  Future<void> _refreshStorePrices() async {
    await GooglePlayBillingService.queryProducts();
    if (!mounted) return;
    setState(() {});
    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.isPremiumOrHigher) {
      FunnelAnalytics.log('paywall_view', {
        'source': widget.source,
        'trial_days': GooglePlayBillingService.proTrialDays,
      });
    }
  }

  @override
  void dispose() {
    if (GooglePlayBillingService.onPurchaseEvent == _onBillingEvent) {
      GooglePlayBillingService.onPurchaseEvent = null;
    }
    super.dispose();
  }

  Future<void> _loadPlan() async {
    await SubscriptionPlanStore.load();
    if (mounted) setState(() => _currentPlan = SubscriptionPlanStore.currentPlan);
  }

  void _onBillingEvent(BillingPurchaseEvent event) {
    if (!mounted) return;

    switch (event.type) {
      case BillingPurchaseEventType.pending:
        setState(() => _purchasingProductId = event.productId);
        break;
      case BillingPurchaseEventType.success:
        if (_purchasingProductId != null) {
          FunnelAnalytics.log('purchase_success', {'source': widget.source});
        }
        setState(() {
          _purchasingProductId = null;
          _isRestoring = false;
          _currentPlan = event.plan ?? _currentPlan;
        });
        SubscriptionPlanStore.load().then((_) {
          if (!mounted) return;
          setState(() => _currentPlan = SubscriptionPlanStore.currentPlan);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Welcome to ${SubscriptionPlanStore.displayNameFor(event.plan ?? 'Expert')}! '
              'Your subscription is active.',
            ),
            backgroundColor: const Color(0xFF43A047),
            behavior: SnackBarBehavior.floating,
          ),
        );
        break;
      case BillingPurchaseEventType.error:
        if (_purchasingProductId != null) {
          FunnelAnalytics.log('purchase_error', {'source': widget.source});
        }
        setState(() {
          _purchasingProductId = null;
          _isRestoring = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(event.message ?? 'Purchase failed.'),
            backgroundColor: const Color(0xFFB71C1C),
            behavior: SnackBarBehavior.floating,
          ),
        );
        break;
      case BillingPurchaseEventType.canceled:
        if (_purchasingProductId != null) {
          FunnelAnalytics.log('purchase_cancel', {'source': widget.source});
        }
        setState(() {
          _purchasingProductId = null;
          _isRestoring = false;
        });
        break;
      case BillingPurchaseEventType.restoring:
        setState(() => _isRestoring = true);
        break;
      case BillingPurchaseEventType.restoreFinished:
        setState(() => _isRestoring = false);
        _loadPlan();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              event.restoreFound
                  ? 'Purchases restored successfully.'
                  : 'No active Google Play subscriptions found.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        break;
    }
  }

  Future<void> _purchasePlan(String plan) async {
    if (_isPro || _purchasingProductId != null || _isRestoring) return;

    if (!GooglePlayBillingService.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google Play subscriptions are available on Android only.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!GooglePlayBillingService.isStoreAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Google Play Billing is unavailable. Check your connection and try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final productId = GooglePlayBillingService.productIdForPlan(plan);
    if (productId == null) return;

    setState(() => _purchasingProductId = productId);
    FunnelAnalytics.log('purchase_start', {
      'source': widget.source,
      'trial_days': GooglePlayBillingService.proTrialDays,
    });
    final started = await GooglePlayBillingService.purchase(productId);
    if (!mounted) return;
    if (!started) {
      setState(() => _purchasingProductId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not start purchase. Verify products in Google Play Console.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _restorePurchases() async {
    if (_purchasingProductId != null || _isRestoring) return;

    if (!GooglePlayBillingService.isAndroid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Restore purchases is available on Android only.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    await GooglePlayBillingService.restorePurchases();
    if (!mounted) return;
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted || !_isRestoring) return;
      setState(() => _isRestoring = false);
      _loadPlan();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Restore complete. If you had a subscription, it should appear shortly.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  bool get _isPro => SubscriptionPlanStore.isPremiumOrHigher;

  @override
  Widget build(BuildContext context) {
    const proColor = Color(0xFFFFB74D);
    final planLabel = SubscriptionPlanStore.displayNameFor(_currentPlan);
    final trialDays = _isPro ? null : GooglePlayBillingService.proTrialDays;
    final price = GooglePlayBillingService.proDisplayPrice;

    return _ProfileDetailScaffold(
      title: 'Subscription',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          _FadeIn(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    proColor.withValues(alpha: 0.18),
                    const Color(0xFF1A1A1A),
                    const Color(0xFF0F0F0F),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: proColor.withValues(alpha: 0.28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: proColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.auto_awesome, color: proColor, size: 26),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isPro ? 'You have the full Oracle' : 'One plan. The full Oracle.',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Current plan: $planLabel',
                              style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _isPro
                        ? 'Every symbol, every timeframe, unlimited setups and AI chat, '
                            'Oracle Vision, Citadel execution, and Oracle Desk — all active.'
                        : 'Everything On Chain Oracle AI does, unlocked with a single subscription. '
                            'No tiers to compare — just the complete toolkit.',
                    style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          _PricingTierCard(
            name: SubscriptionPlanStore.proPlanName,
            tagline: 'Full access to every Oracle tool',
            price: price,
            period: '/month',
            icon: Icons.auto_awesome,
            accentColor: proColor,
            features: const [
              'Any symbol — Top 150 and beyond, including new listings',
              'All timeframes, unlimited AI trade setups',
              'Unlimited Oracle Trader AI Chat',
              'Oracle Vision — live high-conviction opportunities',
              'Oracle Citadel — automated execution on your own exchange keys',
              'Oracle Desk — performance analytics and command center',
              'Advanced alerts: RSI, MACD, Volume, VWAP Cross, News',
            ],
            isCurrent: _isPro,
            badge: trialDays != null ? '$trialDays-DAY FREE TRIAL' : 'FULL ACCESS',
            showUpgradeButton: true,
            upgradeButtonLabel: trialDays != null ? 'Start $trialDays-day free trial' : 'Unlock Oracle Pro',
            isPurchasing: _purchasingProductId == GooglePlayBillingService.proProductId,
            onUpgrade: () => _purchasePlan('Expert'),
          ),
          if (trialDays != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Free for $trialDays days, then $price/month. Cancel anytime in Google Play '
                'before the trial ends and you won\'t be charged.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(context, _premiumPageRoute((_) => const TrackRecordScreen())),
              icon: const Icon(Icons.insights_outlined, size: 18),
              label: const Text('See every setup\'s real results'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00BFFF),
                side: BorderSide(color: const Color(0xFF00BFFF).withValues(alpha: 0.4)),
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          _PricingTierCard(
            name: 'Free',
            tagline: 'Core markets to get started',
            price: '\$0',
            period: '/month',
            icon: Icons.lock_open_outlined,
            accentColor: Colors.grey,
            features: const [
              'Daily analysis on BTC, ETH, and SOL',
              'Watchlist up to ${SubscriptionPlanStore.freeWatchlistMax} coins',
              '${SubscriptionPlanStore.freeTradeSetupsPerDay} Daily trade setups every 24 hours',
              'Basic price alerts',
            ],
            isCurrent: !_isPro,
            badge: null,
            showUpgradeButton: false,
            onUpgrade: () {},
          ),
          Text(
            'AI-generated analysis is for educational purposes only — not financial advice. '
            'Oracle Citadel is non-custodial: you connect your own exchange API keys and are '
            'responsible for all trades.',
            style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: (_purchasingProductId != null || _isRestoring) ? null : _restorePurchases,
              icon: _isRestoring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                    )
                  : const Icon(Icons.restore_rounded, size: 18, color: Color(0xFF00BFFF)),
              label: Text(
                _isRestoring ? 'Restoring…' : 'Restore Purchases',
                style: const TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600),
              ),
            ),
          ),
          Center(
            child: Text(
              'Cancel anytime · Billed through Google Play',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () => openPrivacyPolicy(context),
              child: const Text(
                'Privacy Policy',
                style: TextStyle(color: Color(0xFF00BFFF), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PricingTierCard extends StatelessWidget {
  final String name;
  final String tagline;
  final String price;
  final String period;
  final IconData icon;
  final Color accentColor;
  final List<String> features;
  final bool isCurrent;
  final String? badge;
  final bool showUpgradeButton;
  final String? upgradeButtonLabel;
  final bool isPurchasing;
  final VoidCallback onUpgrade;

  const _PricingTierCard({
    required this.name,
    required this.tagline,
    required this.price,
    required this.period,
    required this.icon,
    required this.accentColor,
    required this.features,
    required this.isCurrent,
    required this.badge,
    required this.showUpgradeButton,
    this.upgradeButtonLabel,
    this.isPurchasing = false,
    required this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final isHighlighted = badge != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isCurrent
                ? const Color(0xFF00E676).withValues(alpha: 0.45)
                : isHighlighted
                    ? accentColor.withValues(alpha: 0.45)
                    : Colors.white.withValues(alpha: 0.06),
            width: isCurrent || isHighlighted ? 1.5 : 1,
          ),
        ),
        child: Container(
          decoration: isHighlighted && !isCurrent
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      accentColor.withValues(alpha: 0.06),
                      Colors.transparent,
                    ],
                  ),
                )
              : null,
          padding: const EdgeInsets.all(_AppSpacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accentColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            if (badge != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: accentColor.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: accentColor.withValues(alpha: 0.35)),
                                ),
                                child: Text(
                                  badge!,
                                  style: TextStyle(fontSize: 10, color: accentColor, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(tagline, style: TextStyle(fontSize: 12, color: Colors.grey[500], height: 1.3)),
                      ],
                    ),
                  ),
                  if (isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'Current',
                        style: TextStyle(fontSize: 11, color: Color(0xFF00E676), fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: name == 'Free' ? Colors.white : accentColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(period, style: TextStyle(fontSize: 14, color: Colors.grey[500])),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
              const SizedBox(height: 14),
              ...features.map(
                (f) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.check_rounded, size: 18, color: accentColor.withValues(alpha: 0.85)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          f,
                          style: TextStyle(fontSize: 14, color: Colors.grey[300], height: 1.35),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showUpgradeButton) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: _ScaleTap(
                    onTap: (isCurrent || isPurchasing) ? null : onUpgrade,
                    child: ElevatedButton(
                      onPressed: (isCurrent || isPurchasing) ? null : onUpgrade,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isCurrent ? Colors.grey[800] : accentColor,
                        foregroundColor: isCurrent ? Colors.grey[500] : Colors.black,
                        disabledBackgroundColor: Colors.grey[800],
                        minimumSize: const Size.fromHeight(50),
                        elevation: isCurrent ? 0 : 2,
                      ),
                      child: isPurchasing
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              isCurrent
                                  ? 'Current Plan'
                                  : (upgradeButtonLabel ?? 'Upgrade to $name'),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                            ),
                    ),
                  ),
                ),
              ] else if (isCurrent) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  ),
                  child: const Text(
                    'Current Plan',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
