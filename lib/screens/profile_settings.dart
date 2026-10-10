// Profile, account, settings, privacy, help, about.

part of '../main.dart';

// ==================== PROFILE & SETTINGS ====================

/// Shared scaffold for Profile sub-screens with consistent styling.
class _ProfileDetailScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final bool showOracleBackdrop;

  const _ProfileDetailScaffold({
    required this.title,
    required this.body,
    this.showOracleBackdrop = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showOracleBackdrop)
            const OracleProfileBackdrop(
              centeredOrb: true,
              orbHeight: kProfileBackgroundOrbHeight,
              orbOpacity: kProfileBackgroundOrbOpacity,
            ),
          Positioned.fill(
            child: SafeArea(
              child: _FadeIn(child: body),
            ),
          ),
        ],
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _planLabel = 'Free Plan';
  bool _isExpert = false;
  String _displayName = UserProfileStore.defaultDisplayName;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    await Future.wait([
      SubscriptionPlanStore.load(),
      UserProfileStore.load(),
    ]);
    if (mounted) {
      setState(() {
        _planLabel = '${SubscriptionPlanStore.displayPlanName} Plan';
        _isExpert = SubscriptionPlanStore.isExpert;
        _displayName = UserProfileStore.displayName;
      });
    }
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.push(context, _premiumPageRoute((_) => screen)).then((_) {
      _loadProfileData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: const Text('Profile'),
        backgroundColor: const Color(0xFF0F0F0F),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const OracleProfileBackdrop(
            centeredOrb: true,
            orbHeight: kProfileBackgroundOrbHeight,
            orbOpacity: kProfileBackgroundOrbOpacity,
          ),
          Positioned.fill(
            child: SafeArea(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  _AppSpacing.screen,
                  12,
                  _AppSpacing.screen,
                  _AppSpacing.screen + MediaQuery.paddingOf(context).bottom + 24,
                ),
                children: [
                  OracleOrbHeroCard(
                    displayName: _displayName,
                    subtitle: _planLabel,
                    onTap: () => _open(context, const AccountScreen()),
                    trailing: Icon(Icons.chevron_right, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: _AppSpacing.section),
                  const _SectionHeader(title: 'Account'),
                  _ProfileMenuTile(
                    icon: Icons.edit_outlined,
                    title: 'Edit Profile',
                    subtitle: 'Display name, email, and timezone',
                    onTap: () async {
                      final saved = await Navigator.push<bool>(
                        context,
                        _premiumPageRoute((_) => const EditProfileScreen()),
                      );
                      if (saved == true) _loadProfileData();
                    },
                  ),
                  _ProfileMenuTile(
                    icon: Icons.person_outline,
                    title: 'Account',
                    subtitle: 'Manage profile and preferences',
                    onTap: () => _open(context, const AccountScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.workspace_premium_outlined,
                    title: 'Subscription Plan',
                    subtitle: 'View or upgrade your plan',
                    onTap: () => _open(context, const SubscriptionPlanScreen(source: 'profile')),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.insights_outlined,
                    title: 'Track Record',
                    subtitle: 'Every daily setup, graded on real candles',
                    onTap: () => _open(context, const TrackRecordScreen()),
                  ),
                  const SizedBox(height: _AppSpacing.item),
                  const _SectionHeader(title: 'Community'),
                  const CommunityLinksSection(),
                  const SizedBox(height: _AppSpacing.item),
                  const _SectionHeader(title: 'App'),
                  _ProfileMenuTile(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    subtitle: 'Notifications, theme, and more',
                    onTap: () => _open(context, const SettingsScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.security_outlined,
                    title: 'Privacy & Security',
                    subtitle: 'Data and account security',
                    onTap: () => _open(context, const PrivacySecurityScreen()),
                  ),
                  if (_isExpert)
                    _ProfileMenuTile(
                      icon: Icons.shield_outlined,
                      title: 'Oracle Citadel',
                      subtitle: 'Configure secure automated trading',
                      onTap: () => showCitadelSetupDialog(context),
                    ),
                  _ProfileMenuTile(
                    icon: Icons.help_outline,
                    title: 'Help & Support',
                    subtitle: 'FAQs and contact support',
                    onTap: () => _open(context, const HelpSupportScreen()),
                  ),
                  _ProfileMenuTile(
                    icon: Icons.info_outline,
                    title: 'About',
                    subtitle: 'On-Chain Oracle AI ${AppVersionInfo.label}',
                    onTap: () => _open(context, const AboutScreen()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileMenuTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ProfileMenuTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _ScaleTap(
        onTap: onTap,
        child: Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF00BFFF), size: 22),
            ),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            trailing: Icon(Icons.chevron_right, color: Colors.grey[600]),
          ),
        ),
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  @override
  void initState() {
    super.initState();
    UserProfileStore.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _openEditProfile() async {
    final saved = await Navigator.push<bool>(
      context,
      _premiumPageRoute((_) => const EditProfileScreen()),
    );
    if (saved == true && mounted) {
      await UserProfileStore.load();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Account',
      showOracleBackdrop: true,
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          _AppSpacing.screen,
          _AppSpacing.screen,
          _AppSpacing.screen,
          _AppSpacing.screen + MediaQuery.paddingOf(context).bottom + 24,
        ),
        children: [
          OracleOrbHeroCard(
            displayName: UserProfileStore.displayName,
            subtitle: UserProfileStore.email,
            profileImagePath: UserProfileStore.avatarPath,
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Profile Details'),
          _AccountField(label: 'Display Name', value: UserProfileStore.displayName),
          _AccountField(label: 'Email', value: UserProfileStore.email),
          _AccountField(
            label: 'Plan Tier',
            value: SubscriptionPlanStore.displayNameFor(UserProfileStore.tier),
          ),
          _AccountField(label: 'Member Since', value: UserProfileStore.memberSince),
          _AccountField(label: 'Timezone', value: UserProfileStore.timezone),
          const SizedBox(height: _AppSpacing.section),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _openEditProfile,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFFF),
                foregroundColor: Colors.black,
              ),
              child: const Text('Edit Profile'),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: const Color(0xFF1A1A1A),
                    title: const Text('Sign out?'),
                    content: const Text(
                      'You will need your email and password to sign back in. Your account stays on this device.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Sign Out', style: TextStyle(color: Color(0xFFFF5252))),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !context.mounted) return;
                await AuthService.signOut();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  PageRouteBuilder<void>(
                    pageBuilder: (_, __, ___) => LoginScreen(
                      onSuccess: (ctx) {
                        Navigator.of(ctx).pushReplacement(
                          MaterialPageRoute<void>(builder: (_) => const MainScreen()),
                        );
                      },
                    ),
                    transitionsBuilder: (_, animation, __, child) =>
                        FadeTransition(opacity: animation, child: child),
                  ),
                  (_) => false,
                );
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF5252),
                side: BorderSide(color: const Color(0xFFFF5252).withValues(alpha: 0.45)),
              ),
              child: const Text('Sign Out'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountField extends StatelessWidget {
  final String label;
  final String value;

  const _AccountField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          subtitle: Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Colors.white)),
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _pushNotifications = true;
  bool _emailAlerts = false;
  bool _analysisComplete = true;
  bool _darkMode = true;
  bool _hapticFeedback = true;
  String _tradingVenueId = TradingVenueStore.autoId;
  double _startingCapital = StartingCapitalStore.capitalUsd;
  late final TextEditingController _capitalController;
  bool _editingCapitalText = false;
  String? _capitalError;

  @override
  void initState() {
    super.initState();
    _capitalController = TextEditingController(text: _formatCapitalInput(_startingCapital));
    TradingVenueStore.load().then((_) {
      if (!mounted) return;
      setState(() => _tradingVenueId = TradingVenueStore.venueId);
    });
    StartingCapitalStore.load().then((_) {
      if (!mounted) return;
      setState(() {
        _startingCapital = StartingCapitalStore.capitalUsd;
        if (!_editingCapitalText) {
          _capitalController.text = _formatCapitalInput(_startingCapital);
        }
      });
    });
    OracleAlertStore.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _capitalController.dispose();
    super.dispose();
  }

  Future<void> _onVenueChanged(String? id) async {
    if (id == null) return;
    await TradingVenueStore.save(id);
    if (!mounted) return;
    setState(() => _tradingVenueId = TradingVenueStore.venueId);
  }

  String _formatCapitalInput(double value) {
    final n = value.round();
    final raw = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final fromEnd = raw.length - i;
      buf.write(raw[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  double? _parseCapitalInput(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  Future<void> _commitCapital(double value) async {
    if (value < StartingCapitalStore.minUsd) {
      final minLabel = StartingCapitalStore.minUsd.round();
      if (!mounted) return;
      setState(() {
        _capitalError = 'Enter at least \$$minLabel — War Room needs a real bankroll.';
        _startingCapital = StartingCapitalStore.minUsd;
        _capitalController.text = _formatCapitalInput(_startingCapital);
      });
      await StartingCapitalStore.save(StartingCapitalStore.minUsd);
      return;
    }
    final next = value.clamp(StartingCapitalStore.minUsd, StartingCapitalStore.maxUsd);
    await StartingCapitalStore.save(next);
    if (!mounted) return;
    setState(() {
      _capitalError = null;
      _startingCapital = StartingCapitalStore.capitalUsd;
      if (!_editingCapitalText) {
        _capitalController.text = _formatCapitalInput(_startingCapital);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Settings',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          const _SectionHeader(title: 'Notifications'),
          _SettingsSwitchTile(
            icon: Icons.notifications_active_outlined,
            title: 'Push Notifications',
            subtitle: 'Receive alerts on your device',
            value: _pushNotifications,
            onChanged: (v) => setState(() => _pushNotifications = v),
          ),
          _SettingsSwitchTile(
            icon: Icons.shield_outlined,
            title: 'Setup Guardians',
            subtitle: 'Entry, stop, and target pings on open setups',
            value: !OracleAlertStore.muteSetup && !OracleAlertStore.muteAll,
            onChanged: (v) async {
              OracleAlertStore.muteSetup = !v;
              await OracleAlertStore.saveMutes();
              if (mounted) setState(() {});
            },
          ),
          _SettingsSwitchTile(
            icon: Icons.auto_awesome_outlined,
            title: 'Desk Pulse',
            subtitle: 'Bias flips (Oracle Pro)',
            value: !OracleAlertStore.mutePulse && !OracleAlertStore.muteAll,
            onChanged: (v) async {
              OracleAlertStore.mutePulse = !v;
              await OracleAlertStore.saveMutes();
              if (mounted) setState(() {});
            },
          ),
          _SettingsSwitchTile(
            icon: Icons.account_balance_outlined,
            title: 'Citadel live',
            subtitle: 'Fills and near-stop (Expert)',
            value: !OracleAlertStore.muteCitadel && !OracleAlertStore.muteAll,
            onChanged: (v) async {
              OracleAlertStore.muteCitadel = !v;
              await OracleAlertStore.saveMutes();
              if (mounted) setState(() {});
            },
          ),
          _SettingsSwitchTile(
            icon: Icons.attach_money,
            title: 'Custom price alerts',
            subtitle: 'Optional levels you arm yourself',
            value: !OracleAlertStore.mutePrice && !OracleAlertStore.muteAll,
            onChanged: (v) async {
              OracleAlertStore.mutePrice = !v;
              await OracleAlertStore.saveMutes();
              if (mounted) setState(() {});
            },
          ),
          _SettingsSwitchTile(
            icon: Icons.analytics_outlined,
            title: 'Analysis Complete',
            subtitle: 'Notify when AI analysis finishes',
            value: _analysisComplete,
            onChanged: (v) => setState(() => _analysisComplete = v),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'Trading venue'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.account_balance_outlined, color: Color(0xFF00BFFF), size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'I trade on',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _tradingVenueId,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF1A1A1A),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF0A0A0A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Color(0xFF00BFFF), width: 1.5),
                      ),
                    ),
                    items: TradingVenueStore.options
                        .map(
                          (opt) => DropdownMenuItem(
                            value: opt.id,
                            child: Text(opt.label, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: _onVenueChanged,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    TradingVenueStore.current.note ??
                        'AI analysis, trade setups, and chat will treat this as your execution venue — even if Citadel cannot place orders there yet.',
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'Starting capital'),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.account_balance_wallet_outlined, color: Color(0xFF00BFFF), size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Bankroll',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _capitalController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
                    ],
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18, letterSpacing: -0.2),
                    decoration: InputDecoration(
                      prefixText: '\$ ',
                      prefixStyle: TextStyle(color: Colors.grey[400], fontWeight: FontWeight.w600, fontSize: 18),
                      hintText: '10,000',
                      filled: true,
                      fillColor: const Color(0xFF0A0A0A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[800]!),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                        borderSide: BorderSide(color: Color(0xFF00BFFF), width: 1.5),
                      ),
                    ),
                    onTap: () => _editingCapitalText = true,
                    onChanged: (raw) {
                      final parsed = _parseCapitalInput(raw);
                      if (parsed == null) return;
                      if (parsed < StartingCapitalStore.minUsd) {
                        setState(() {
                          _capitalError =
                              'Enter at least \$${StartingCapitalStore.minUsd.round()} — War Room needs a real bankroll.';
                        });
                        return;
                      }
                      final next = parsed.clamp(StartingCapitalStore.minUsd, StartingCapitalStore.maxUsd);
                      setState(() {
                        _capitalError = null;
                        _startingCapital = next;
                      });
                      StartingCapitalStore.save(next);
                    },
                    onTapOutside: (_) {
                      _editingCapitalText = false;
                      _commitCapital(_parseCapitalInput(_capitalController.text) ?? _startingCapital);
                      FocusManager.instance.primaryFocus?.unfocus();
                    },
                    onEditingComplete: () {
                      _editingCapitalText = false;
                      _commitCapital(_parseCapitalInput(_capitalController.text) ?? _startingCapital);
                      FocusScope.of(context).unfocus();
                    },
                    onSubmitted: (_) {
                      _editingCapitalText = false;
                      _commitCapital(_parseCapitalInput(_capitalController.text) ?? _startingCapital);
                    },
                  ),
                  if (_capitalError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _capitalError!,
                      style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12.5, height: 1.35),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFF00BFFF),
                      inactiveTrackColor: Colors.grey[800],
                      thumbColor: const Color(0xFF00BFFF),
                      overlayColor: const Color(0xFF00BFFF).withValues(alpha: 0.16),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      min: StartingCapitalStore.minUsd,
                      max: StartingCapitalStore.maxUsd,
                      value: _startingCapital.clamp(StartingCapitalStore.minUsd, StartingCapitalStore.maxUsd),
                      onChanged: (v) {
                        _editingCapitalText = false;
                        setState(() {
                          _capitalError = null;
                          _startingCapital = v;
                          _capitalController.text = _formatCapitalInput(v);
                        });
                      },
                      onChangeEnd: _commitCapital,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '\$${StartingCapitalStore.minUsd.round()}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                      Text('\$1,000,000', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _StartingCapitalPresets(
                    selected: _startingCapital,
                    onSelect: (v) {
                      _editingCapitalText = false;
                      _capitalController.text = _formatCapitalInput(v);
                      _commitCapital(v);
                    },
                  ),
                  const SizedBox(height: 10),
                  _PositionAtRiskLine(
                    capital: _startingCapital,
                    riskPercent: OracleCitadelStore.defaultRiskPercent,
                    leverage: OracleCitadelStore.defaultLeverage,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'War Room AI Alpha uses this bankroll x each trade\'s risk % x leverage x R-multiple. '
                    'Change it anytime — the snapshot recalculates immediately.',
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'Appearance'),
          _SettingsSwitchTile(
            icon: Icons.dark_mode_outlined,
            title: 'Dark Mode',
            subtitle: 'Always on (app default)',
            value: _darkMode,
            onChanged: (v) => setState(() => _darkMode = v),
          ),
          const SizedBox(height: _AppSpacing.item),
          const _SectionHeader(title: 'General'),
          _SettingsSwitchTile(
            icon: Icons.vibration,
            title: 'Haptic Feedback',
            subtitle: 'Vibrate on button taps',
            value: _hapticFeedback,
            onChanged: (v) => setState(() => _hapticFeedback = v),
          ),
          _ProfileMenuTile(
            icon: Icons.language,
            title: 'Language',
            subtitle: 'English (US)',
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Language selection — coming soon')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StartingCapitalPresets extends StatelessWidget {
  final double selected;
  final ValueChanged<double> onSelect;

  const _StartingCapitalPresets({required this.selected, required this.onSelect});

  static const _presets = <(double, String)>[
    (1000, '\$1k'),
    (5000, '\$5k'),
    (10000, '\$10k'),
    (25000, '\$25k'),
    (50000, '\$50k'),
    (100000, '\$100k'),
    (250000, '\$250k'),
    (500000, '\$500k'),
    (1000000, '\$1M'),
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _presets.map((preset) {
        final active = (selected - preset.$1).abs() < 0.5;
        return GestureDetector(
          onTap: () => onSelect(preset.$1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: active ? const Color(0xFF00BFFF).withValues(alpha: 0.18) : const Color(0xFF0A0A0A),
              border: Border.all(
                color: active ? const Color(0xFF00BFFF) : Colors.grey[800]!,
              ),
            ),
            child: Text(
              preset.$2,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? const Color(0xFF00BFFF) : Colors.grey[400],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          secondary: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: const Color(0xFF00BFFF), size: 22),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          value: value,
          activeThumbColor: const Color(0xFF00BFFF),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class PrivacySecurityScreen extends StatelessWidget {
  const PrivacySecurityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Privacy & Security',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(_AppSpacing.card),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.shield_outlined, color: const Color(0xFF00BFFF).withValues(alpha: 0.9)),
                      const SizedBox(width: 10),
                      const Text('Your Data', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'On-Chain Oracle AI respects your privacy. We do not collect or store your exchange API '
                    'secrets, wallet addresses, or trading balances. We only collect anonymous usage analytics. '
                    'Subscriptions are handled by Google Play. We do not sell or share personal data.',
                    style: TextStyle(fontSize: 14, height: 1.55, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.item),
          _PrivacySection(
            title: 'Data Collection',
            body: 'Anonymous usage analytics only. Trade setup and analysis history are stored locally '
                'on your device. Exchange API keys for Oracle Citadel are encrypted server-side; '
                'we never store wallet addresses or balances.',
          ),
          _PrivacySection(
            title: 'Subscriptions',
            body: 'Oracle Pro is billed monthly through Google Play '
                '(${GooglePlayBillingService.fallbackProPrice}/mo; local Play price may vary). '
                'Manage or cancel subscriptions in your Google Play account settings.',
          ),
          _PrivacySection(
            title: 'Third-Party Services',
            body: 'Charts powered by TradingView. Price data from Binance and CoinGecko. '
                'News from NewsAPI. Each service has its own privacy policy.',
          ),
          const SizedBox(height: _AppSpacing.section),
          _ProfileMenuTile(
            icon: Icons.policy_outlined,
            title: 'Privacy Policy',
            subtitle: 'Read our full privacy policy',
            onTap: () => openPrivacyPolicy(context),
          ),
          _ProfileMenuTile(
            icon: Icons.delete_outline,
            title: 'Delete Account',
            subtitle: 'Permanently remove your data',
            onTap: () => openSupportEmail(context),
          ),
        ],
      ),
    );
  }
}

class _PrivacySection extends StatelessWidget {
  final String title;
  final String body;

  const _PrivacySection({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(_AppSpacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(body, style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400])),
            ],
          ),
        ),
      ),
    );
  }
}

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  static const _faqs = [
    (
      'How do I run an analysis?',
      'Tap the Analyze tab, enter a coin symbol (e.g. BTC), and press Get Analysis. '
          'Results appear with a live chart and AI report.',
    ),
    (
      'What is Trade Setup?',
      'Trade Setup generates execution-ready levels (Entry, SL, TP1, TP2) with a minimum 2.1:1 risk-reward ratio.',
    ),
    (
      'How does the watchlist work?',
      'On Home, tap + to add coins. Tap any watchlist coin to open its chart instantly.',
    ),
    (
      'How is win rate calculated?',
      'Win rate tracks closed trade setups marked Win or Loss based on live price vs your levels.',
    ),
    (
      'Can I upgrade my plan?',
      'Go to Profile → Subscription to unlock Oracle Pro — one plan with full access to every tool.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'Help & Support',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              leading: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF00BFFF).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.mail_outline, color: Color(0xFF00BFFF)),
              ),
              title: const Text('Contact Support', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(kSupportEmail, style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              trailing: Icon(Icons.open_in_new, size: 18, color: Colors.grey[600]),
              onTap: () => openSupportEmail(context),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          const _SectionHeader(title: 'Frequently Asked Questions'),
          ..._faqs.map(
            (faq) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                child: Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    title: Text(faq.$1, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    iconColor: const Color(0xFF00BFFF),
                    collapsedIconColor: Colors.grey[600],
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          faq.$2,
                          style: TextStyle(fontSize: 14, height: 1.5, color: Colors.grey[400]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _ProfileDetailScaffold(
      title: 'About',
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(_AppSpacing.screen),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
              child: Column(
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF00BFFF).withValues(alpha: 0.3),
                          const Color(0xFF1A1A1A),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF00BFFF).withValues(alpha: 0.3)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        kAppLogoAsset,
                        width: 80,
                        height: 80,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, __, ___) => Image.asset(
                          'assets/images/app_icon.png',
                          width: 80,
                          height: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'On-Chain Oracle AI',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    AppVersionInfo.aboutLine,
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.section),
          _AboutInfoRow(label: 'Developer', value: 'On-Chain Oracle Team'),
          _AboutInfoRow(label: 'Platform', value: 'Flutter'),
          _AboutInfoRow(label: 'Release', value: 'May 2026'),
          const SizedBox(height: _AppSpacing.item),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(_AppSpacing.card),
              child: Text(
                'On-Chain Oracle AI delivers AI-powered crypto market analysis and trade setups for '
                'educational purposes. Charts, watchlists, Oracle Vision, and performance tracking — '
                'all in one app.\n\n$kReportDisclaimer',
                style: TextStyle(fontSize: 14, height: 1.55, color: Colors.grey[400]),
              ),
            ),
          ),
          const SizedBox(height: _AppSpacing.item),
          _ProfileMenuTile(
            icon: Icons.policy_outlined,
            title: 'Privacy Policy',
            subtitle: kPrivacyPolicyUrl,
            onTap: () => openPrivacyPolicy(context),
          ),
          const SizedBox(height: _AppSpacing.section),
          Center(
            child: Text(
              '© 2026 On-Chain Oracle AI. All rights reserved.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _AboutInfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          title: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
      ),
    );
  }
}
