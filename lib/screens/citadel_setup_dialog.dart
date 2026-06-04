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

// ─── Legal & exchange guidance copy (exact user-provided text) ───────────────

const String kCitadelSecurityDisclaimer =
    'Your API keys are 100% yours. We never see or store your Secret. '
    'Oracle Citadel is completely non-custodial. You control all trading permissions.\n\n'
    '• Never enable Withdrawals or Fund Transfers\n'
    '• Enable IP restrictions + Trade Only permissions\n'
    '• You are solely responsible for all trades and losses\n'
    '• This is NOT financial advice. Trading involves substantial risk of loss. Always DYOR.';

const List<({String title, String reason})> _kCitadelRecommendedExchanges = [
  (title: 'Coinbase Advanced Trade', reason: 'Strong US regulation and reliability'),
  (title: 'Kraken', reason: 'Excellent security and API'),
  (title: 'Gemini', reason: 'Regulatory-first platform'),
  (title: 'Crypto.com', reason: 'Good compliance and features'),
  (title: 'Binance.US (in supported states)', reason: 'US-compliant where available'),
];

const String _kCitadelNotRecommendedSummary =
    'Binance.com (international), Bybit, OKX, KuCoin, MEXC, Bitget, BloFin, Phemex';

const String _kCitadelNotRecommendedReason =
    'Offshore platforms with stricter restrictions in many countries.';

// ─── Premium palette (Citadel Setup only) ───────────────────────────────────

const Color _kCitadelOrange = Color(0xFFFF9800);
const Color _kCitadelOrangeMuted = Color(0xFF3D2E1A);
const Color _kCitadelGreen = Color(0xFF43A047);
const Color _kCitadelGreenMuted = Color(0xFF1B3320);
const Color _kCitadelCard = Color(0xFF1E1E1E);
const Color _kCitadelSurface = Color(0xFF141414);

/// POST /exchange_keys with BloFin demo fields (keeps OracleCitadelService unchanged).
Future<void> _citadelLinkExchangeKeys({
  required String userId,
  required String exchangeApiKey,
  required String exchangeApiSecret,
  required String exchange,
  required bool useDemoMode,
  required double riskPercent,
}) async {
  final uri = Uri.parse('$kCitadelBaseUrl/exchange_keys');
  final response = await http
      .post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': OracleCitadelStore.apiKey,
        },
        body: jsonEncode({
          'user_id': userId,
          'api_key': exchangeApiKey,
          'api_secret': exchangeApiSecret,
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
                const _CitadelDisclaimerCard(compact: true),
                const SizedBox(height: 20),
                _CitadelGuideSection(
                  exchange: 'Binance',
                  steps: const [
                    'Log in → Profile → API Management → Create API.',
                    'Label the key (e.g. "Oracle Citadel") and complete 2FA.',
                    'Enable only "Enable Spot & Margin Trading" — never Withdrawals.',
                    'Optional: restrict to trusted IPs under "Restrict access to trusted IPs".',
                    'Copy API Key and Secret once; Secret is shown only once.',
                  ],
                ),
                _CitadelGuideSection(
                  exchange: 'Bybit',
                  steps: const [
                    'Account & Security → API → Create New Key.',
                    'Choose "System-generated API Keys" and set a clear note.',
                    'Permissions: Read-Write with Trade only; disable Withdraw and Transfer.',
                    'Bind IP whitelist if your network has a static IP.',
                    'Save Key and Secret securely; paste into Citadel Setup.',
                  ],
                ),
                _CitadelGuideSection(
                  exchange: 'OKX',
                  steps: const [
                    'Profile → API → Create V5 API key.',
                    'Passphrase is required — store it with your Secret.',
                    'Permissions: Trade only; do not enable Withdrawal.',
                    'Add IP whitelist under API key settings when possible.',
                    'Confirm via email/2FA, then copy Key and Secret.',
                  ],
                ),
                _CitadelGuideSection(
                  exchange: 'Coinbase Advanced',
                  steps: const [
                    'Settings → API → New API Key.',
                    'Select portfolio and permissions: View + Trade only.',
                    'Do not grant Transfer or Withdraw permissions.',
                    'Use API key restrictions (IP allowlist) if available.',
                    'Download or copy credentials immediately after creation.',
                  ],
                ),
                _CitadelGuideSection(
                  exchange: 'Kraken',
                  steps: const [
                    'Settings → API → Add key.',
                    'Enable Query Funds and Create & Modify Orders only.',
                    'Never enable Withdraw, Deposit, or Transfer permissions.',
                    'Set nonce window and IP restriction for added safety.',
                    'Generate and copy Key + Private Key (Secret).',
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

/// Orange-accent legal disclaimer card (top of setup screen).
class _CitadelDisclaimerCard extends StatelessWidget {
  final bool compact;

  const _CitadelDisclaimerCard({this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: _kCitadelOrangeMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kCitadelOrange.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: _kCitadelOrange.withValues(alpha: 0.08),
            blurRadius: 12,
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
                  color: _kCitadelOrange.withValues(alpha: 0.18),
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
                      'Important — Read Before Connecting',
                      style: TextStyle(
                        fontSize: compact ? 13 : 14,
                        fontWeight: FontWeight.w700,
                        color: Colors.orange[100],
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      kCitadelSecurityDisclaimer,
                      style: TextStyle(
                        fontSize: compact ? 12 : 13,
                        height: 1.55,
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

/// Green "Connected" status — shown after successful exchange key save.
class _CitadelConnectionStatusCard extends StatelessWidget {
  final String exchangeLabel;
  final bool demoMode;
  final DateTime lastConnected;

  const _CitadelConnectionStatusCard({
    required this.exchangeLabel,
    required this.demoMode,
    required this.lastConnected,
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
    final accent = recommended ? const Color(0xFF00BFFF) : Colors.redAccent.shade200;
    final bg = recommended
        ? const Color(0xFF0D2230)
        : const Color(0xFF2A1A1A);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: _kCitadelCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.25)),
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          iconColor: accent,
          collapsedIconColor: Colors.grey[500],
          title: Row(
            children: [
              Icon(
                recommended ? Icons.verified_outlined : Icons.warning_amber_rounded,
                color: accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  recommended
                      ? 'Recommended Exchanges (Safer & Compliant)'
                      : 'Not Recommended (Higher Regulatory Risk)',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          children: [
            if (recommended)
              ..._kCitadelRecommendedExchanges.map((item) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('• ', style: TextStyle(color: accent, fontSize: 14, height: 1.4)),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[300]),
                            children: [
                              TextSpan(
                                text: '${item.title} — ',
                                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                              ),
                              TextSpan(text: item.reason),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              })
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• $_kCitadelNotRecommendedSummary',
                      style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[300]),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('→ ', style: TextStyle(color: accent, fontSize: 14)),
                        Expanded(
                          child: Text(
                            _kCitadelNotRecommendedReason,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: Colors.redAccent.shade100,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
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
  late final TextEditingController _apiKeyController;
  late final TextEditingController _exchangeKeyController;
  late final TextEditingController _exchangeSecretController;
  late final TextEditingController _riskController;

  bool _saving = false;
  bool _useDemoMode = false;

  /// Shown after successful exchange key link (also restored from prefs on open).
  bool _isExchangeLinked = false;
  bool _saveJustCompleted = false;
  String _connectedExchangeLabel = 'Exchange';
  DateTime? _lastConnectedAt;

  @override
  void initState() {
    super.initState();
    _userIdController = TextEditingController(text: OracleCitadelStore.userId);
    _apiKeyController = TextEditingController(text: OracleCitadelStore.apiKey);
    _exchangeKeyController = TextEditingController();
    _exchangeSecretController = TextEditingController();
    _riskController = TextEditingController(
      text: OracleCitadelStore.defaultRiskPercent.toString(),
    );
    _loadCitadelUiPrefs();
  }

  Future<void> _loadCitadelUiPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    final linked = prefs.getBool(_kCitadelExchangeLinkedPref) ?? false;
    final label = prefs.getString(_kCitadelConnectedExchangePref) ?? 'Exchange';
    final iso = prefs.getString(_kCitadelLastConnectedPref);
    DateTime? lastConnected;
    if (iso != null && iso.isNotEmpty) {
      lastConnected = DateTime.tryParse(iso);
    }

    setState(() {
      _useDemoMode = prefs.getBool(_kCitadelDemoModePref) ?? false;
      _isExchangeLinked = linked && OracleCitadelStore.isConfigured;
      _connectedExchangeLabel = label;
      _lastConnectedAt = lastConnected;
    });
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
    if (_useDemoMode) return 'BloFin';
    return _connectedExchangeLabel.isNotEmpty ? _connectedExchangeLabel : 'Exchange';
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _apiKeyController.dispose();
    _exchangeKeyController.dispose();
    _exchangeSecretController.dispose();
    _riskController.dispose();
    super.dispose();
  }

  void _safePopDialog() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  void _showSnackOnParent(String message) {
    final parent = widget.parentContext;
    if (!parent.mounted) return;
    ScaffoldMessenger.of(parent).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: _kCitadelGreen,
      ),
    );
  }

  Future<void> _onSavePressed() async {
    if (_saving || !mounted) return;

    setState(() => _saving = true);

    final risk = double.tryParse(_riskController.text.trim()) ?? 1.0;

    try {
      await OracleCitadelStore.save(
        userId: _userIdController.text,
        apiKey: _apiKeyController.text,
        riskPercent: risk,
      );
      if (!mounted) return;

      final exchangeKey = _exchangeKeyController.text.trim();
      final exchangeSecret = _exchangeSecretController.text.trim();
      if (exchangeKey.isNotEmpty && exchangeSecret.isNotEmpty) {
        await _persistCitadelUiPrefs();
        if (!mounted) return;
        final exchangeForApi = _useDemoMode ? _kCitadelBlofinExchangeId : '';
        await _citadelLinkExchangeKeys(
          userId: OracleCitadelStore.userId,
          exchangeApiKey: exchangeKey,
          exchangeApiSecret: exchangeSecret,
          exchange: exchangeForApi,
          useDemoMode: _useDemoMode,
          riskPercent: risk,
        );
        final label = _useDemoMode ? 'BloFin' : 'Exchange API';
        await _persistConnectionStatus(exchangeLabel: label, demoMode: _useDemoMode);
        if (!mounted) return;
        setState(() {
          _isExchangeLinked = true;
          _saveJustCompleted = true;
          _connectedExchangeLabel = label;
          _lastConnectedAt = DateTime.now();
        });
        _showSnackOnParent('Oracle Citadel connected successfully');
        return;
      }

      if (!mounted) return;
      _safePopDialog();
      _showSnackOnParent('Oracle Citadel settings saved');
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

    return PopScope(
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
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Oracle Citadel',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.3),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Secure automated execution',
                            style: TextStyle(fontSize: 13, color: Colors.grey),
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
                        ),
                        const SizedBox(height: 18),
                      ],
                      const _CitadelDisclaimerCard(),
                      const SizedBox(height: 16),
                      const _CitadelExchangeGuidanceSection(recommended: true),
                      const _CitadelExchangeGuidanceSection(recommended: false),
                      const SizedBox(height: 20),
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
                      _CitadelSetupField(
                        label: 'App API Key (X-API-Key)',
                        controller: _apiKeyController,
                        obscure: true,
                        enabled: !_saving,
                      ),
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
                      const SizedBox(height: 12),
                      _CitadelSetupField(
                        label: 'Risk % per trade',
                        controller: _riskController,
                        enabled: !_saving,
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
                            'BloFin demo only — fake funds on the testnet API',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          value: _useDemoMode,
                          activeThumbColor: const Color(0xFF00BFFF),
                          onChanged: _saving
                              ? null
                              : (value) {
                                  if (!mounted) return;
                                  setState(() => _useDemoMode = value);
                                },
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
                                  'Using BloFin Demo with fake funds',
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
    );
  }
}

class _CitadelSetupField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final bool enabled;

  const _CitadelSetupField({
    required this.label,
    required this.controller,
    this.obscure = false,
    this.enabled = true,
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
