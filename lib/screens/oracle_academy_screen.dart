// Oracle Academy — static lessons + Ask Oracle (Premium+).

part of '../main.dart';

class OracleAcademyScreen extends StatelessWidget {
  const OracleAcademyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: const Text('Learn', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text(
            'Core fundamentals in the Oracle voice. Free can read every lesson. Ask Oracle is Premium+ and remembers this lesson’s thread.',
            style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.grey[400]),
          ),
          const SizedBox(height: 6),
          Text(
            'NFA / DYOR — education only, not financial advice.',
            style: TextStyle(fontSize: 12, height: 1.4, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          for (final lesson in OracleAcademyLessons.all) ...[
            _AcademyLessonTile(lesson: lesson, cyan: cyan),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _AcademyLessonTile extends StatelessWidget {
  final OracleAcademyLesson lesson;
  final Color cyan;

  const _AcademyLessonTile({required this.lesson, required this.cyan});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1A1A),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.push(
            context,
            _premiumPageRoute((_) => OracleAcademyLessonScreen(lesson: lesson)),
          );
        },
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Icon(Icons.menu_book_outlined, color: cyan, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(lesson.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(lesson.subtitle, style: TextStyle(fontSize: 12.5, height: 1.35, color: Colors.grey[500])),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[600]),
            ],
          ),
        ),
      ),
    );
  }
}

class OracleAcademyLessonScreen extends StatelessWidget {
  final OracleAcademyLesson lesson;

  const OracleAcademyLessonScreen({super.key, required this.lesson});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00BFFF);
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F0F0F),
        title: Text(lesson.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
              children: [
                Text(lesson.subtitle, style: TextStyle(fontSize: 14, height: 1.4, color: cyan.withValues(alpha: 0.9))),
                const SizedBox(height: 14),
                Text(lesson.body.trim(), style: TextStyle(fontSize: 15, height: 1.55, color: Colors.grey[200])),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () async {
                    await SubscriptionPlanStore.load();
                    if (!context.mounted) return;
                    if (!SubscriptionPlanStore.hasAiChatAccess) {
                      _showChatUpgradePrompt(context, minimumTier: 'Premium');
                      return;
                    }
                    Navigator.push(
                      context,
                      _premiumPageRoute(
                        (_) => ChatScreen(
                          lessonId: lesson.id,
                          lessonTitle: lesson.title,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(kOracleAiChatIcon, size: 18),
                  label: const Text('Ask Oracle', style: TextStyle(fontWeight: FontWeight.w800)),
                  style: FilledButton.styleFrom(
                    backgroundColor: cyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
