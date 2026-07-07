// ─── Oracle Citadel Setup — premium modal (this file only) ───────────────────
//
// Lifecycle: controllers live in [_CitadelSetupDialog] State; disposed in
// State.dispose() only after the route tears down (avoids _dependents.isEmpty).
//
// BloFin Demo: toggle persists locally; POST /exchange_keys sends exchange=blofin
// + use_demo_mode when enabled (backend uses demo Open API host).
//
part of '../main.dart';

/// SharedPreferences — connection status shown after successful key link.
const String _kCitadelDemoModePref = 'citadel_use_demo_mode';
const String _kCitadelLastConnectedPref = 'citadel_last_connected_iso';
const String _kCitadelConnectedExchangePref = 'citadel_connected_exchange_label';
const String _kCitadelExchangeLinkedPref = 'citadel_exchange_linked';

/// BloFin exchange id sent when linking keys (live vs demo resolved on backend).
const String _kCitadelBlofinExchangeId = 'blofin';
const String _kCitadelBitunixExchangeId = 'bitunix';

// ─── Legal & exchange guidance copy ─────────────────────────────────────────

const String kCitadelSetupTagline = 'Live trade execution on your exchange';

const String kCitadelLegalDisclaimer =
    'Oracle Citadel is a non-custodial LIVE execution tool. Unless you explicitly '
    'enable Demo/Testnet Mode, every order sent through Citadel is a real market order '
    'on your connected exchange using real funds.\n\n'
    'On-Chain Oracle does not hold your funds, does not provide investment advice, '
    'and is not a broker-dealer or financial institution.\n\n'
    'You are solely responsible for API key security, exchange selection, and every '
    'live trade placed through your account. Past performance and AI-generated analysis '
    'do not guarantee future results. Cryptocurrency trading involves substantial risk '
    'of loss, including total loss of capital.\n\n'
    'By connecting an exchange you confirm that you understand these risks, that live '
    'execution is the default, that you comply with applicable laws in your jurisdiction, '
    'and that you will never enable withdrawal or transfer permissions on API keys used '
    'with this app.\n\n'
    'Demo Mode uses testnet/fake funds. Live trading uses real money and carries full risk of loss.';

const String _kCitadelPrimaryRecommendedTitle = 'Kraken (Recommended)';
const String _kCitadelPrimaryRecommendedReason =
    'US & EU regulated • Up to 50x leverage • Strongest compliance & security';

const String _kCitadelNotRecommendedTitle = 'BloFin (Demo Mode Only)';
const String _kCitadelNotRecommendedWarning =
    'Demo/testnet trading only in Citadel — simulated funds for testing. '
    'Live execution uses Bitunix or other supported exchanges.';

// ─── Premium palette (Citadel Setup only) ───────────────────────────────────

const Color _kCitadelOrange = Color(0xFFFF9800);
const Color _kCitadelOrangeMuted = Color(0xFF3D2A18);
const Color _kCitadelGreen = Color(0xFF43A047);
const Color _kCitadelGreenMuted = Color(0xFF1B3320);
const Color _kCitadelCard = Color(0xFF1E1E1E);
const Color _kCitadelSurface = Color(0xFF141414);

/// POST /exchange_keys with BloFin demo fields (keeps OracleCitadelService unchanged).
Future<void> _citadelLinkExchangeKeys({
  required String userId,
  required String exchangeApiKey,
  required String exchangeApiSecret,
  required String exchangePassphrase,
  required String exchange,
  required bool useDemoMode,
  required double riskPercent,
}) async {
  final appKey = await AppApiKeyService.ensureKey();
  await OracleCitadelStore.load();
  final uid = userId.trim().isNotEmpty ? userId.trim() : OracleCitadelStore.userId;
  final uri = Uri.parse('$kCitadelBaseUrl/exchange_keys');
  final response = await http
      .post(
        uri,
        headers: await AppApiKeyService.backendHeaders(),
        body: jsonEncode({
          'user_id': uid,
          'app_api_key': appKey,
          'api_key': exchangeApiKey,
          'api_secret': exchangeApiSecret,
          if (exchangePassphrase.isNotEmpty) ...{
            'exchange_passphrase': exchangePassphrase,
            'passphrase': exchangePassphrase,
          },
          'exchange': exchange,
          'use_demo_mode': useDemoMode,
          'demo_mode': useDemoMode,
          'risk_percent': riskPercent,
        }),
      )
      .timeout(const Duration(seconds: 30));

  if (response.statusCode == 200) return;

  String? friendly;
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      if (decoded['user_message'] is String) friendly = decoded['user_message'] as String;
      final detail = decoded['detail'];
      if (friendly == null && detail is String) friendly = detail;
    }
  } catch (_) {}
  throw OracleCitadelException(
    friendly ?? 'Could not save exchange keys (${response.statusCode}).',
  );
}

String _formatCitadelLastConnected(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final month = months[local.month - 1];
  var hour = local.hour;
  final ampm = hour >= 12 ? 'PM' : 'AM';
  hour = hour % 12;
  if (hour == 0) hour = 12;
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month ${local.day}, ${local.year} · $hour:$minute $ampm';
}

void _showCitadelSetupGuideSheet(BuildContext context) {
  if (!context.mounted) return;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: _kCitadelSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (sheetCtx) {
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.45,
        maxChildSize: 0.92,
        builder: (_, scrollController) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: ListView(
              controller: scrollController,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[700],
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'How to Set Up API Keys',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                const _CitadelLegalDisclaimerCard(compact: true),
                const SizedBox(height: 20),
                _CitadelGuideSection(
                  exchange: 'Kraken (Recommended — LIVE default)',
                  steps: const [
                    'Log in → Settings → API → Add key.',
                    'Label the key (e.g. "Oracle Citadel") and complete 2FA.',
                    'Enable Query Funds and Create & Modify Orders only — never Withdraw, Deposit, or Transfer.',
                    'Set IP restriction and nonce window when offered.',
                    'Copy API Key and Private Key (Secret) once; Secret is shown only once.',
                    'Paste into Citadel Setup with Demo Mode OFF — trades execute LIVE on Kraken.',
                  ],
                ),
                _CitadelGuideSection(
                  exchange: 'BloFin (Demo Mode Only — testing)',
                  steps: const [
                    'BloFin in Citadel is demo/testnet only — simulated funds, no live orders.',
                    'Use BloFin Demo API keys; Demo Mode is enabled automatically for BloFin.',
                    'API Management → Create key → Trade permissions only; disable Withdrawals.',
                    'Set the API Passphrase when creating the key — you must enter the same passphrase in Citadel Setup.',
                    'Copy API Key and Secret immediately; paste Key, Secret, and Passphrase into Oracle Citadel Setup.',
                    'For LIVE trading, connect Bitunix (or another supported live exchange) instead.',
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'After creating keys on your exchange, enter them in Oracle Citadel Setup and tap Save.',
                  style: TextStyle(fontSize: 12, height: 1.45, color: Colors.grey[600]),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// Prominent legal disclaimer — placed at the bottom of the setup screen.
class _CitadelLegalDisclaimerCard extends StatelessWidget {
  final bool compact;

  const _CitadelLegalDisclaimerCard({this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _kCitadelOrangeMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kCitadelOrange.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: _kCitadelOrange.withValues(alpha: 0.1),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: _kCitadelOrange.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.gavel_rounded,
                  color: _kCitadelOrange,
                  size: compact ? 20 : 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      compact ? 'Legal Notice' : 'Legal Disclaimer & Risk Disclosure',
                      style: TextStyle(
                        fontSize: compact ? 13 : 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.orange[100],
                        letterSpacing: 0.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      kCitadelLegalDisclaimer,
                      style: TextStyle(
                        fontSize: compact ? 11.5 : 12.5,
                        height: 1.6,
                        color: Colors.grey[300],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Note near exchange API fields — demo vs live key separation.
class _CitadelDemoKeysNotice extends StatelessWidget {
  const _CitadelDemoKeysNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF00BFFF).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline_rounded, color: Color(0xFF00BFFF), size: 18),
              SizedBox(width: 8),
              Text(
                'Demo vs Live API Keys',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF00BFFF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey[400]),
              children: const [
                TextSpan(text: 'Demo Mode is enabled by default when using demo keys.\n'),
                TextSpan(
                  text: 'Demo keys and Live keys are completely different.\n',
                  style: TextStyle(
                    fontStyle: FontStyle.italic,
                    color: Color(0xFF00BFFF),
                  ),
                ),
                TextSpan(
                  text: 'Please generate separate keys for Demo vs Live trading on your exchange.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Premium leverage selector — 1x–100x, persisted locally.
class _CitadelLeverageSelector extends StatelessWidget {
  final double leverage;
  final bool enabled;
  final ValueChanged<double> onChanged;

  static const _presets = [1, 5, 10, 25, 50, 100];

  const _CitadelLeverageSelector({
    required this.leverage,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final rounded = leverage.round();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: _kCitadelCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00BFFF).withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tune_rounded, color: Color(0xFF00BFFF), size: 18),
              const SizedBox(width: 8),
              const Text(
                'Preferred leverage',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF00BFFF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.4)),
                ),
                child: Text(
                  '${rounded}x',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF00BFFF),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF00BFFF),
              inactiveTrackColor: Colors.grey[800],
              thumbColor: const Color(0xFF00BFFF),
              overlayColor: const Color(0xFF00BFFF).withValues(alpha: 0.12),
              trackHeight: 4,
            ),
            child: Slider(
              value: leverage.clamp(1, 100),
              min: 1,
              max: 100,
              divisions: 99,
              label: '${rounded}x',
              onChanged: enabled ? onChanged : null,
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _presets.map((preset) {
              final selected = rounded == preset;
              return GestureDetector(
                onTap: enabled ? () => onChanged(preset.toDouble()) : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: selected
                        ? const Color(0xFF00BFFF).withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.25),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF00BFFF).withValues(alpha: 0.55)
                          : Colors.grey[800]!,
                    ),
                  ),
                  child: Text(
                    '${preset}x',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: selected ? const Color(0xFF00BFFF) : Colors.grey[500],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 6),
          Text(
            'Applied on your connected exchange before each Citadel MARKET order.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey[600], height: 1.35),
          ),
        ],
      ),
    );
  }
}

/// Green "Connected" status — shown after successful exchange key save.
class _CitadelConnectionStatusCard extends StatelessWidget {
  final String exchangeLabel;
  final bool demoMode;
  final DateTime lastConnected;
  final int leverage;

  const _CitadelConnectionStatusCard({
    required this.exchangeLabel,
    required this.demoMode,
    required this.lastConnected,
    required this.leverage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _kCitadelGreenMuted,
            const Color(0xFF152218),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kCitadelGreen.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: _kCitadelGreen.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _kCitadelGreen,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: _kCitadelGreen.withValues(alpha: 0.35),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
                    SizedBox(width: 6),
                    Text(
                      'Connected',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 14,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (demoMode)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00BFFF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'Demo Mode',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF00BFFF),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.account_balance_rounded, color: Colors.green[200], size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  exchangeLabel,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 15, color: Colors.grey[500]),
              const SizedBox(width: 6),
              Text(
                'Last connected ${_formatCitadelLastConnected(lastConnected)}',
                style: TextStyle(fontSize: 12.5, color: Colors.grey[400], height: 1.3),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.bolt_rounded, size: 15, color: Colors.orange[200]),
              const SizedBox(width: 6),
              Text(
                'Leverage: ${leverage}x',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.orange[100],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Expandable recommended / not-recommended exchange guidance.
class _CitadelExchangeGuidanceSection extends StatelessWidget {
  final bool recommended;

  const _CitadelExchangeGuidanceSection({required this.recommended});

  @override
  Widget build(BuildContext context) {
    final accent = recommended ? const Color(0xFF00BFFF) : const Color(0xFFE57373);
    final headerBg = recommended
        ? const Color(0xFF0D2230).withValues(alpha: 0.6)
        : const Color(0xFF2A1818).withValues(alpha: 0.6);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _kCitadelCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.3)),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor: headerBg,
          collapsedBackgroundColor: Colors.transparent,
          iconColor: accent,
          collapsedIconColor: Colors.grey[500],
          title: Row(
            children: [
              Icon(
                recommended ? Icons.verified_user_outlined : Icons.report_gmailerrorred_outlined,
                color: accent,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  recommended
                      ? 'Recommended Exchanges (Safer & Compliant)'
                      : 'Not Recommended (Higher Regulatory Risk)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              recommended
                  ? 'US and EU-aligned venues with stronger oversight'
                  : 'Offshore platforms — use at your own regulatory risk',
              style: TextStyle(fontSize: 11.5, color: Colors.grey[500], height: 1.3),
            ),
          ),
          children: [
            if (recommended) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.verified_outlined, color: accent, size: 16),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[300]),
                          children: [
                            TextSpan(
                              text: '$_kCitadelPrimaryRecommendedTitle\n',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                fontSize: 13.5,
                              ),
                            ),
                            TextSpan(
                              text: _kCitadelPrimaryRecommendedReason,
                              style: TextStyle(color: Colors.grey[400]),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded, color: accent, size: 16),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[300]),
                          children: [
                            TextSpan(
                              text: '$_kCitadelNotRecommendedTitle\n',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.red[100],
                                fontSize: 13.5,
                              ),
                            ),
                            TextSpan(
                              text: _kCitadelNotRecommendedWarning,
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Expandable API key setup guide — matches exchange guidance card style.
class _CitadelApiKeysHowToSection extends StatelessWidget {
  const _CitadelApiKeysHowToSection();

  static const _accent = Color(0xFF00BFFF);

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _kCitadelCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _accent.withValues(alpha: 0.3)),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          backgroundColor: const Color(0xFF0D2230).withValues(alpha: 0.6),
          collapsedBackgroundColor: Colors.transparent,
          iconColor: _accent,
          collapsedIconColor: Colors.grey[500],
          title: const Row(
            children: [
              Icon(Icons.vpn_key_outlined, color: _accent, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'How to Connect API Keys',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Step-by-step setup and security checklist',
              style: TextStyle(fontSize: 11.5, color: Colors.grey, height: 1.3),
            ),
          ),
          children: const [
            _CitadelHowToBlock(
              title: 'Before you start (LIVE default)',
              steps: [
                'Citadel executes LIVE market orders on your exchange unless Demo Mode is enabled.',
                'Create a dedicated API key on Kraken (recommended) or BloFin — never enable withdrawals.',
                'Label the key "Oracle Citadel" and complete all exchange security prompts.',
                'Copy Key and Secret once, then paste below and tap Save & Connect.',
              ],
            ),
            _CitadelHowToBlock(
              title: 'Kraken (Recommended — LIVE trading)',
              steps: [
                'Settings → API → Add key → name it "Oracle Citadel".',
                'Permissions: Query Funds + Create & Modify Orders only.',
                'Disable Withdraw, Deposit, and Transfer permissions.',
                'Enable IP restriction if your connection uses a fixed IP.',
                'Keep Demo Mode OFF — all Citadel orders execute as LIVE trades on Kraken.',
              ],
            ),
            _CitadelHowToBlock(
              title: 'BloFin (Demo Mode Only — testing)',
              steps: [
                'BloFin in Citadel is demo/testnet only — orders use simulated funds, never real money.',
                'Use BloFin Demo API keys; Demo Mode turns on automatically when BloFin is selected.',
                'API Management → Create key → Trade only; disable Withdrawals and Transfers.',
                'Set and remember the API Passphrase — Citadel requires it for BloFin.',
                'For LIVE trading, connect Bitunix (or another supported live exchange).',
              ],
            ),
            _CitadelHowToBlock(
              title: 'Security best practices',
              bullets: [
                'Default is LIVE execution — verify Demo Mode is off before connecting production keys.',
                'Use separate keys for Kraken vs BloFin and for live vs demo testing.',
                'Bind IP whitelist on the exchange whenever static IPs are available.',
                'Oracle Citadel is non-custodial — trading permissions only, no withdrawal access.',
              ],
            ),
            _CitadelHowToBlock(
              title: 'Demo vs live mode',
              isWarning: true,
              bullets: [
                'Mode is set by exchange: BloFin = Demo only, Bitunix = Live only.',
                'Live trading (Bitunix) places real MARKET orders with real funds.',
                'Demo Mode (BloFin Demo) uses simulated funds for testing only.',
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CitadelHowToBlock extends StatelessWidget {
  final String title;
  final List<String> steps;
  final List<String> bullets;
  final bool isWarning;

  const _CitadelHowToBlock({
    required this.title,
    this.steps = const [],
    this.bullets = const [],
    this.isWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = isWarning ? const Color(0xFFFFB74D) : const Color(0xFF00BFFF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isWarning ? Colors.orange[100] : Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          ...steps.asMap().entries.map((e) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e.key + 1}. ',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey[500], height: 1.45),
                  ),
                  Expanded(
                    child: Text(
                      e.value,
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
                    ),
                  ),
                ],
              ),
            );
          }),
          ...bullets.map((b) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ', style: TextStyle(fontSize: 12.5, color: accent, height: 1.45)),
                  Expanded(
                    child: Text(
                      b,
                      style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[400]),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _CitadelGuideSection extends StatelessWidget {
  final String exchange;
  final List<String> steps;

  const _CitadelGuideSection({required this.exchange, required this.steps});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            exchange,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF00BFFF),
            ),
          ),
          const SizedBox(height: 8),
          ...List.generate(steps.length, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                  Expanded(
                    child: Text(
                      steps[i],
                      style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey[400]),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

Future<void> showCitadelSetupDialog(BuildContext context) async {
  if (!context.mounted) return;
  await OracleCitadelStore.load();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    builder: (dialogContext) => _CitadelSetupDialog(
      parentContext: context,
    ),
  );
}

class _CitadelSetupDialog extends StatefulWidget {
  final BuildContext parentContext;

  const _CitadelSetupDialog({required this.parentContext});

  @override
  State<_CitadelSetupDialog> createState() => _CitadelSetupDialogState();
}

class _CitadelSetupDialogState extends State<_CitadelSetupDialog> {
  late final TextEditingController _userIdController;
  late final TextEditingController _exchangeKeyController;
  late final TextEditingController _exchangeSecretController;
  late final TextEditingController _exchangePassphraseController;
  late final TextEditingController _riskController;

  bool _saving = false;
  bool _useDemoMode = true;
  String _selectedExchange = _kCitadelBlofinExchangeId;

  bool get _isBitunix => _selectedExchange == _kCitadelBitunixExchangeId;
  bool get _isBlofin => !_isBitunix;

  /// Shown after successful exchange key link (also restored from prefs on open).
  bool _isExchangeLinked = false;
  bool _saveJustCompleted = false;
  DateTime? _lastConnectedAt;
  double _leverage = 5;
  String _appApiKey = '';

  @override
  void initState() {
    super.initState();
    _userIdController = TextEditingController(text: OracleCitadelStore.userId);
    _exchangeKeyController = TextEditingController();
    _exchangeSecretController = TextEditingController();
    _exchangePassphraseController = TextEditingController();
    _riskController = TextEditingController(
      text: OracleCitadelStore.defaultRiskPercent.toString(),
    );
    _leverage = OracleCitadelStore.defaultLeverage;
    _exchangeKeyController.addListener(_syncDemoModeFromExchangeKeys);
    _exchangeSecretController.addListener(_syncDemoModeFromExchangeKeys);
    _loadCitadelUiPrefs();
  }

  bool _looksLikeDemoExchangeKeys() {
    final key = _exchangeKeyController.text.trim().toLowerCase();
    final secret = _exchangeSecretController.text.trim().toLowerCase();
    if (key.isEmpty && secret.isEmpty) return false;
    const markers = ['demo', 'testnet', 'sandbox', 'paper'];
    final combined = '$key $secret';
    return markers.any(combined.contains);
  }

  Future<void> _syncDemoModeFromExchangeKeys() async {
    if (!mounted || _saving || !_looksLikeDemoExchangeKeys()) return;
    if (!_isBlofin || _useDemoMode) return;
    setState(() => _useDemoMode = true);
    await OracleCitadelStore.saveDemoMode(true);
    await _persistCitadelUiPrefs();
  }

  Future<void> _loadCitadelUiPrefs() async {
    await AppApiKeyService.ensureKey();
    await OracleCitadelStore.load();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    var linked = prefs.getBool(_kCitadelExchangeLinkedPref) ?? false;
    final demoPref = prefs.getBool(_kCitadelDemoModePref) ?? true;
    if (OracleCitadelStore.isConfigured && linked) {
      linked = await OracleCitadelService.verifyServerLinked();
      if (!linked) {
        await OracleCitadelStore.clearExchangeLinked();
      }
    } else {
      linked = false;
    }
    final iso = prefs.getString(_kCitadelLastConnectedPref);
    DateTime? lastConnected;
    if (iso != null && iso.isNotEmpty) {
      lastConnected = DateTime.tryParse(iso);
    }

    // Mode follows the exchange: Bitunix = live-only, BloFin = demo-only.
    final restoredExchange = OracleCitadelStore.selectedExchange;
    final coercedDemo =
        restoredExchange == _kCitadelBitunixExchangeId ? false : true;
    if (coercedDemo != demoPref) {
      await OracleCitadelStore.saveDemoMode(coercedDemo);
      await prefs.setBool(_kCitadelDemoModePref, coercedDemo);
    }
    if (!mounted) return;

    setState(() {
      _useDemoMode = coercedDemo;
      OracleCitadelStore.useDemoMode = coercedDemo;
      _selectedExchange = restoredExchange;
      _isExchangeLinked = linked && OracleCitadelStore.isConfigured;
      _lastConnectedAt = lastConnected;
      _leverage = OracleCitadelStore.defaultLeverage;
      _appApiKey = OracleCitadelStore.apiKey;
      _userIdController.text = OracleCitadelStore.userId;
    });
  }

  Future<void> _onLeverageChanged(double value) async {
    if (!mounted) return;
    setState(() => _leverage = value);
    await OracleCitadelStore.saveLeverage(value);
  }

  Future<void> _persistConnectionStatus({
    required String exchangeLabel,
    required bool demoMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc();
    await prefs.setBool(_kCitadelDemoModePref, demoMode);
    await prefs.setBool(_kCitadelExchangeLinkedPref, true);
    await prefs.setString(_kCitadelConnectedExchangePref, exchangeLabel);
    await prefs.setString(_kCitadelLastConnectedPref, now.toIso8601String());
  }

  Future<void> _persistCitadelUiPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCitadelDemoModePref, _useDemoMode);
  }

  String get _displayExchangeLabel {
    if (_isBitunix) return 'Bitunix Live';
    return 'BloFin Demo';
  }

  @override
  void dispose() {
    _exchangeKeyController.removeListener(_syncDemoModeFromExchangeKeys);
    _exchangeSecretController.removeListener(_syncDemoModeFromExchangeKeys);
    _userIdController.dispose();
    _exchangeKeyController.dispose();
    _exchangeSecretController.dispose();
    _exchangePassphraseController.dispose();
    _riskController.dispose();
    super.dispose();
  }

  void _safePopDialog() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showSnackOnParent(String message, {bool useParent = false}) {
    final target = useParent ? widget.parentContext : context;
    if (!target.mounted) return;
    ScaffoldMessenger.of(target).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _kCitadelGreen,
        elevation: 12,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      ),
    );
  }

  Future<void> _onSavePressed() async {
    if (_saving || !mounted) return;

    setState(() => _saving = true);

    final risk = double.tryParse(_riskController.text.trim()) ?? 1.0;

    try {
      await AppApiKeyService.ensureKey();
      await OracleCitadelStore.load();
      await OracleCitadelStore.saveLeverage(_leverage);
      await OracleCitadelStore.saveDemoMode(_useDemoMode);
      await OracleCitadelStore.save(
        userId: _userIdController.text,
        apiKey: OracleCitadelStore.apiKey,
        riskPercent: risk,
      );
      await AppApiKeyService.syncUserId(OracleCitadelStore.userId);
      await AppApiKeyService.registerWithBackend(
        userId: OracleCitadelStore.userId,
        apiKey: OracleCitadelStore.apiKey,
      );
      if (!mounted) return;

      final exchangeKey = _exchangeKeyController.text.trim();
      final exchangeSecret = _exchangeSecretController.text.trim();
      final exchangePassphrase = _exchangePassphraseController.text.trim();
      if (_looksLikeDemoExchangeKeys() && _isBlofin) {
        if (!_useDemoMode) {
          setState(() => _useDemoMode = true);
        }
        await OracleCitadelStore.saveDemoMode(true);
        await _persistCitadelUiPrefs();
      }
      if (exchangeKey.isNotEmpty && exchangeSecret.isNotEmpty) {
        if (_isBlofin && exchangePassphrase.isEmpty) {
          throw OracleCitadelException(
            'BloFin API Passphrase is required. Enter the passphrase you set when creating your API key.',
          );
        }
        if (_isBitunix && _useDemoMode) {
          setState(() => _useDemoMode = false);
          await OracleCitadelStore.saveDemoMode(false);
        }
        if (_isBlofin && !_useDemoMode) {
          // BloFin is demo-only in Citadel — never send live mode.
          setState(() => _useDemoMode = true);
          await OracleCitadelStore.saveDemoMode(true);
        }
        await OracleCitadelStore.saveSelectedExchange(_selectedExchange);
        await _persistCitadelUiPrefs();
        if (!mounted) return;
        await _citadelLinkExchangeKeys(
          userId: OracleCitadelStore.userId,
          exchangeApiKey: exchangeKey,
          exchangeApiSecret: exchangeSecret,
          exchangePassphrase: exchangePassphrase,
          exchange: _selectedExchange,
          // Bitunix = live-only; BloFin = demo-only.
          useDemoMode: _isBitunix ? false : true,
          riskPercent: risk,
        );
        final verified = await OracleCitadelService.verifyServerLinked();
        if (!verified) {
          throw OracleCitadelException(
            'Keys were sent but the server could not verify them. '
            'Try Save & Connect again, or contact support if this persists.',
          );
        }
        final label = _isBitunix ? 'Bitunix Live' : 'BloFin Demo';
        await _persistConnectionStatus(exchangeLabel: label, demoMode: _useDemoMode);
        if (!mounted) return;
        setState(() {
          _isExchangeLinked = true;
          _saveJustCompleted = true;
          _lastConnectedAt = DateTime.now();
        });
        final pending = await CitadelPendingTradeStore.load();
        _showSnackOnParent('Oracle Citadel connected successfully');
        if (pending != null) {
          if (!mounted) return;
          _safePopDialog();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!widget.parentContext.mounted) return;
          _showCitadelExecuteChoiceDialog(
            widget.parentContext,
            reportText: pending.reportText,
            coin: pending.coin,
            direction: pending.direction,
            plannedEntry: pending.entry,
            stopLoss: pending.stopLoss,
            tp1: pending.tp1,
            tp2: pending.tp2,
          );
        }
        return;
      }

      final serverOk = await OracleCitadelService.verifyServerLinked();
      if (!serverOk) {
        throw OracleCitadelException(
          _isBitunix
              ? 'Bitunix API Key and Secret are required on the server. Enter them below and tap Save & Connect.'
              : 'BloFin API Key, Secret, and Passphrase are required on the server. '
                  'Enter them below and tap Save & Connect.',
        );
      }

      if (!mounted) return;
      _safePopDialog();
      _showSnackOnParent('Oracle Citadel settings saved', useParent: true);
    } on OracleCitadelException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.userMessage),
          backgroundColor: const Color(0xFFB71C1C),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Setup failed. Check connection and try again.'),
          backgroundColor: Color(0xFFB71C1C),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showConnected = _isExchangeLinked && _lastConnectedAt != null;
    final maxH = MediaQuery.sizeOf(context).height * 0.88;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: PopScope(
        canPop: !_saving,
        child: Dialog(
          backgroundColor: _kCitadelSurface,
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 440, maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Header ─────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 12, 0),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.shield_outlined, color: Color(0xFF00BFFF), size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Oracle Citadel',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            kCitadelSetupTagline,
                            style: TextStyle(fontSize: 13, color: Colors.grey[400], height: 1.35),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'How to set up API keys',
                      icon: const Icon(Icons.info_outline_rounded, color: Color(0xFF00BFFF)),
                      onPressed: _saving
                          ? null
                          : () {
                              if (!mounted) return;
                              _showCitadelSetupGuideSheet(context);
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // ── Scrollable body ────────────────────────────────────────────
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showConnected) ...[
                        _CitadelConnectionStatusCard(
                          exchangeLabel: _displayExchangeLabel,
                          demoMode: _useDemoMode,
                          lastConnected: _lastConnectedAt!,
                          leverage: _leverage.round(),
                        ),
                        const SizedBox(height: 18),
                      ],
                      Text(
                        'Connection credentials',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[400],
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _CitadelSetupField(label: 'User ID', controller: _userIdController, enabled: !_saving),
                      const SizedBox(height: 12),
                      _CitadelAppApiKeyCard(apiKey: _appApiKey, enabled: !_saving),
                      const SizedBox(height: 12),
                      Text(
                        'Exchange',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[400],
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: _kCitadelBlofinExchangeId,
                            label: Text(
                              'BloFin (Demo Mode Only)',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12),
                            ),
                            icon: Icon(Icons.science_outlined, size: 18),
                          ),
                          ButtonSegment(
                            value: _kCitadelBitunixExchangeId,
                            label: Text('Bitunix'),
                            icon: Icon(Icons.candlestick_chart_rounded, size: 18),
                          ),
                        ],
                        selected: {_selectedExchange},
                        style: ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        onSelectionChanged: _saving
                            ? null
                            : (selection) async {
                                if (!mounted || selection.isEmpty) return;
                                final next = selection.first;
                                setState(() {
                                  _selectedExchange = next;
                                  if (next == _kCitadelBitunixExchangeId) {
                                    _useDemoMode = false;
                                  } else if (next == _kCitadelBlofinExchangeId) {
                                    // BloFin is demo-only — live execution uses Bitunix.
                                    _useDemoMode = true;
                                  }
                                });
                                await OracleCitadelStore.saveSelectedExchange(next);
                                await OracleCitadelStore.saveDemoMode(_useDemoMode);
                                await _persistCitadelUiPrefs();
                              },
                      ),
                      if (_isBitunix) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Bitunix is live-only (API Key + Secret). No passphrase required.',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey[500], height: 1.35),
                        ),
                      ],
                      if (_isBlofin) ...[
                        const SizedBox(height: 8),
                        Text(
                          'BloFin is demo/testnet only in Citadel — simulated funds. For live trading use Bitunix.',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey[500], height: 1.35),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const _CitadelDemoKeysNotice(),
                      const SizedBox(height: 12),
                      _CitadelSetupField(
                        label: 'Exchange API Key',
                        controller: _exchangeKeyController,
                        obscure: true,
                        enabled: !_saving,
                      ),
                      const SizedBox(height: 12),
                      _CitadelSetupField(
                        label: 'Exchange API Secret',
                        controller: _exchangeSecretController,
                        obscure: true,
                        enabled: !_saving,
                      ),
                      const SizedBox(height: 14),
                      if (_isBlofin)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF9800).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFFF9800).withValues(alpha: 0.45)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.key_outlined, color: Color(0xFFFF9800), size: 18),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'BloFin API Passphrase — required for demo trades',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFFFF9800),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              _CitadelSetupField(
                                label: 'API Passphrase',
                                controller: _exchangePassphraseController,
                                obscure: true,
                                enabled: !_saving,
                                hintText: 'Same passphrase you set when creating the BloFin API key',
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Without this, demo orders fail with signature errors. Each API key has its own passphrase.',
                                style: TextStyle(fontSize: 11.5, color: Colors.grey[500], height: 1.35),
                              ),
                            ],
                          ),
                        ),
                      if (_isBlofin) const SizedBox(height: 12),
                      _CitadelSetupField(
                        label: 'Risk % per trade',
                        controller: _riskController,
                        enabled: !_saving,
                      ),
                      const SizedBox(height: 14),
                      _CitadelLeverageSelector(
                        leverage: _leverage,
                        enabled: !_saving,
                        onChanged: _onLeverageChanged,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          color: _kCitadelCard,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.grey[800]!),
                        ),
                        child: SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                          title: const Text(
                            'Use Demo/Testnet Mode',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            _isBitunix
                                ? 'Bitunix supports live trading only — Demo stays OFF.'
                                : 'BloFin is Demo Mode only — Demo stays ON. Use Bitunix for live trading.',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          value: _useDemoMode,
                          activeThumbColor: const Color(0xFF00BFFF),
                          // Mode is dictated by the exchange: Bitunix = live-only,
                          // BloFin = demo-only. The toggle is informational.
                          onChanged: null,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
                        child: Text(
                          '(Set automatically by exchange: BloFin = Demo only, Bitunix = Live only.)',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey[600], height: 1.35),
                        ),
                      ),
                      if (_useDemoMode) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00BFFF).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.3)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.science_outlined, color: Color(0xFF00BFFF), size: 18),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Demo active — testnet only, not LIVE trading',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF00BFFF),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_saveJustCompleted) ...[
                        const SizedBox(height: 16),
                        Text(
                          'Your connection is active. Tap Done to close.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text(
                        'Exchange guidance',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.grey[400],
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '(e.g. USA, Canada, UK, EU countries have stricter regulations)',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey[500], height: 1.35),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Bitunix is supported for live Citadel execution; BloFin is demo-only for testing. More exchanges coming soon.',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Color(0xFF00BFFF),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const _CitadelExchangeGuidanceSection(recommended: true),
                      const _CitadelExchangeGuidanceSection(recommended: false),
                      const _CitadelApiKeysHowToSection(),
                      const SizedBox(height: 20),
                      const _CitadelLegalDisclaimerCard(),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              // ── Footer actions ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 12, 22, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () {
                                if (!mounted) return;
                                _safePopDialog();
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey[400],
                          side: BorderSide(color: Colors.grey[700]!),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(_saveJustCompleted ? 'Done' : 'Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        onPressed: _saving
                            ? null
                            : (_saveJustCompleted ? _safePopDialog : _onSavePressed),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00BFFF),
                          foregroundColor: Colors.black,
                          disabledBackgroundColor: const Color(0xFF00BFFF).withValues(alpha: 0.4),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        child: _saving
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                              )
                            : Text(
                                _saveJustCompleted ? 'Done' : 'Save & Connect',
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// Read-only App API Key with copy — generated automatically on first launch / login.
class _CitadelAppApiKeyCard extends StatelessWidget {
  final String apiKey;
  final bool enabled;

  const _CitadelAppApiKeyCard({required this.apiKey, this.enabled = true});

  @override
  Widget build(BuildContext context) {
    final displayKey = apiKey.isNotEmpty ? apiKey : 'Generating…';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[800]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'App API Key (X-API-Key)',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            'This is your unique App API Key. Keep it safe.',
            style: TextStyle(fontSize: 12, height: 1.4, color: Colors.grey[600]),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  displayKey,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.35),
                ),
              ),
              IconButton(
                tooltip: 'Copy App API Key',
                onPressed: !enabled || apiKey.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: apiKey));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('App API Key copied'),
                            behavior: SnackBarBehavior.floating,
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                icon: const Icon(Icons.copy_rounded, size: 20, color: Color(0xFF00BFFF)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CitadelSetupField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool enabled;
  final String? hintText;

  const _CitadelSetupField({
    required this.label,
    required this.controller,
    this.obscure = false,
    this.enabled = true,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        hintStyle: TextStyle(color: Colors.grey[700], fontSize: 12),
        labelStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF0A0A0A),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[800]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00BFFF), width: 1.5),
        ),
      ),
    );
  }
}
