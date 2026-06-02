// ─── Oracle Citadel Setup modal — disclaimer & setup guide ───────────────────
//
// Added: (1) visible security disclaimer below the form fields, (2) small
// Icons.info_outline next to the title, (3) bottom sheet "How to Set Up API Keys"
// with step-by-step exchange instructions + full disclaimer. Existing fields,
// buttons, colors, and spacing are unchanged.
//
part of '../main.dart';

/// Exact security disclaimer copy shown in the modal and info sheet.
const String kCitadelSecurityDisclaimer =
    'Your API keys are 100% yours. We never see your Secret. You can revoke or delete '
    'the key instantly from the exchange at any time. For maximum safety, we recommend '
    'enabling IP restrictions and only giving trading permissions. Never enable '
    'Withdrawals or Fund transfers.';

void _showCitadelSetupGuideSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF1A1A1A),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
                const SizedBox(height: 12),
                Text(
                  kCitadelSecurityDisclaimer,
                  style: TextStyle(fontSize: 13, height: 1.5, color: Colors.grey[400]),
                ),
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
  await OracleCitadelStore.load();
  final userIdController = TextEditingController(text: OracleCitadelStore.userId);
  final apiKeyController = TextEditingController(text: OracleCitadelStore.apiKey);
  final exchangeKeyController = TextEditingController();
  final exchangeSecretController = TextEditingController();
  final riskController = TextEditingController(
    text: OracleCitadelStore.defaultRiskPercent.toString(),
  );

  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Expanded(
            child: Text('Oracle Citadel Setup', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          IconButton(
            tooltip: 'How to set up API keys',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.info_outline, color: Color(0xFF00BFFF), size: 20),
            onPressed: () => _showCitadelSetupGuideSheet(ctx),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Link once to enable secure automated trading. Keys are encrypted on the server.',
              style: TextStyle(fontSize: 13, height: 1.45, color: Colors.grey[400]),
            ),
            const SizedBox(height: 14),
            _CitadelSetupField(label: 'User ID', controller: userIdController),
            const SizedBox(height: 10),
            _CitadelSetupField(label: 'App API Key (X-API-Key)', controller: apiKeyController, obscure: true),
            const SizedBox(height: 10),
            _CitadelSetupField(label: 'Exchange API Key', controller: exchangeKeyController, obscure: true),
            const SizedBox(height: 10),
            _CitadelSetupField(label: 'Exchange API Secret', controller: exchangeSecretController, obscure: true),
            const SizedBox(height: 10),
            _CitadelSetupField(label: 'Risk % per trade', controller: riskController),
            const SizedBox(height: 14),
            Text(
              kCitadelSecurityDisclaimer,
              style: TextStyle(fontSize: 11.5, height: 1.45, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),
        ),
        TextButton(
          onPressed: () async {
            final risk = double.tryParse(riskController.text.trim()) ?? 1.0;
            await OracleCitadelStore.save(
              userId: userIdController.text,
              apiKey: apiKeyController.text,
              riskPercent: risk,
            );
            try {
              if (exchangeKeyController.text.trim().isNotEmpty &&
                  exchangeSecretController.text.trim().isNotEmpty) {
                await OracleCitadelService.linkExchangeKeys(
                  userId: OracleCitadelStore.userId,
                  exchangeApiKey: exchangeKeyController.text.trim(),
                  exchangeApiSecret: exchangeSecretController.text.trim(),
                );
              }
              if (ctx.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Oracle Citadel configured successfully')),
                );
              }
            } on OracleCitadelException catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.userMessage)));
              }
            } catch (_) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Setup failed. Check connection and try again.')),
                );
              }
            }
          },
          child: const Text('Save', style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );

  userIdController.dispose();
  apiKeyController.dispose();
  exchangeKeyController.dispose();
  exchangeSecretController.dispose();
  riskController.dispose();
}

class _CitadelSetupField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;

  const _CitadelSetupField({
    required this.label,
    required this.controller,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF0F0F0F),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Colors.grey[800]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF00BFFF)),
        ),
      ),
    );
  }
}
