// Oracle Trader AI chat.

part of '../main.dart';

class ChatScreen extends StatefulWidget {
  final String? lessonId;
  final String? lessonTitle;

  const ChatScreen({super.key, this.lessonId, this.lessonTitle});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late List<Map<String, String>> _messages;
  bool _sending = false;
  bool _loadingThread = false;

  bool get _isLesson => (widget.lessonId ?? '').isNotEmpty;

  String get _greeting {
    if (_isLesson) {
      final title = widget.lessonTitle ?? 'this lesson';
      return 'Academy mode — $title. Ask about the idea. I will teach first. I will not dump a live trade until the concept is locked. NFA / DYOR.';
    }
      return 'Oracle Trader AI online. Ask about the market, Daily VWAP, structure, funding, levels, or risk — I\'ll give you a direct, actionable read.';
  }

  @override
  void initState() {
    super.initState();
    _messages = [
      {'role': 'assistant', 'text': _greeting},
    ];
    if (_isLesson) {
      _loadingThread = true;
      _restoreLessonThread();
    }
  }

  Future<void> _restoreLessonThread() async {
    final saved = await OracleAcademyStore.loadThread(widget.lessonId!);
    if (!mounted) return;
    setState(() {
      if (saved.isNotEmpty) {
        _messages = saved;
      }
      _loadingThread = false;
    });
    _scrollToBottom();
  }

  Future<void> _persistLessonThread() async {
    if (!_isLesson) return;
    await OracleAcademyStore.saveThread(widget.lessonId!, _messages);
  }

  Future<void> _newLessonChat() async {
    if (!_isLesson) return;
    await OracleAcademyStore.clearThread(widget.lessonId!);
    if (!mounted) return;
    setState(() {
      _messages = [
        {'role': 'assistant', 'text': _greeting},
      ];
    });
    await _persistLessonThread();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || _loadingThread) return;

    await SubscriptionPlanStore.load();
    if (!SubscriptionPlanStore.hasAiChatAccess) {
      if (mounted) _showChatUpgradePrompt(context, minimumTier: 'Premium');
      return;
    }
    if (SubscriptionPlanStore.isPremium && !await SubscriptionPlanStore.canSendChatMessage()) {
      if (mounted) _showChatDailyLimitPrompt(context);
      return;
    }

    setState(() {
      _sending = true;
      _messages.add({'role': 'user', 'text': text});
      _controller.clear();
    });
    _scrollToBottom();
    await _persistLessonThread();

    try {
      final history = _messages
          .sublist(0, _messages.length - 1)
          .map((m) => {'role': m['role']!, 'content': m['text']!})
          .toList();
      if (history.length > OracleAcademyStore.maxTurns) {
        history.removeRange(0, history.length - OracleAcademyStore.maxTurns);
      }

      final lesson = _isLesson ? OracleAcademyLessons.byId(widget.lessonId!) : null;
      final systemPrompt = lesson != null
          ? oracleAcademyChatSystemPrompt(lesson)
          : oracleTraderChatSystemPrompt();

      final response = await _postChatWithRetry(
        message: text,
        history: history,
        systemPrompt: systemPrompt,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final reply = (data['reply'] ?? '').toString().trim();
        await SubscriptionPlanStore.recordPremiumChatMessage();
        if (mounted) {
          setState(() {
            _messages.add({
              'role': 'assistant',
              'text': reply.isNotEmpty ? reply : 'No response received. Please try again.',
            });
          });
          await _persistLessonThread();
        }
      } else {
        debugPrint('[Chat] HTTP ${response.statusCode}: ${response.body}');
        if (mounted) {
          setState(() {
            _messages.add({
              'role': 'assistant',
              'text': 'Unable to reach Oracle Trader AI right now. Check your connection and retry.',
            });
          });
        }
      }
    } catch (e) {
      debugPrint('[Chat] Request failed: $e');
      if (mounted) {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'text': 'Connection error. Ensure the backend is running and try again.',
          });
        });
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        title: Text(_isLesson ? (widget.lessonTitle ?? 'Academy') : 'Oracle Trader AI'),
        backgroundColor: const Color(0xFF0F0F0F),
        actions: [
          if (_isLesson)
            TextButton(
              onPressed: _newLessonChat,
              child: const Text('New chat', style: TextStyle(color: Color(0xFF00BFFF), fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.all(_AppSpacing.screen),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (context, index) {
                if (_sending && index == _messages.length) {
                  return const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00BFFF)),
                      ),
                    ),
                  );
                }
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                    decoration: BoxDecoration(
                      color: isUser
                          ? const Color(0xFF00BFFF).withValues(alpha: 0.18)
                          : const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                    ),
                    child: Text(msg['text'] ?? '', style: const TextStyle(height: 1.45)),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(_AppSpacing.screen, 8, _AppSpacing.screen, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: !_sending,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Ask Oracle Trader AI...',
                        prefixIcon: Icon(Icons.auto_awesome, color: Color(0xFF00BFFF), size: 20),
                      ),
                      onSubmitted: _sending ? null : (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FloatingActionButton.small(
                    heroTag: 'chat_send',
                    backgroundColor: const Color(0xFF00BFFF),
                    foregroundColor: Colors.black,
                    onPressed: _sending ? null : _sendMessage,
                    child: const Icon(Icons.send_rounded, size: 20),
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

// ─── UI polish tokens & helpers (visual only) ───────────────────────────────
