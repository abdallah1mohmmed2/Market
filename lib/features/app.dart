import 'dart:async';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../core/theme.dart';
import '../core/permissions.dart';
import '../core/system_config.dart';
import '../data/repositories/repositories.dart';
import '../domain/accounting/calculations.dart';
import '../services/admin_service.dart';
import '../services/backup_service.dart';
import '../services/report_service.dart';
import '../services/device_notification_settings.dart';

const _blue = Color(0xff287bff),
    _cyan = Color(0xff00d7ff),
    _purple = Color(0xff7c4dff),
    _green = Color(0xff18e58c);

String money(Object? v) =>
    '${(v is num ? v : num.tryParse('$v') ?? 0).round()} ريال';
String friendlyError(Object e) {
  if (e is ArgumentError && e.message != null) return '${e.message}';
  if (e is StateError) return e.message;
  final x = '$e';
  if (x.contains('carried_diesel_liters') || x.contains('no such column')) return 'نسخة قاعدة البيانات قديمة. أعد فتح التطبيق ليتم تحديث قاعدة البيانات تلقائيًا.';
  if (x.contains('UNIQUE')) return 'القيمة موجودة مسبقًا.';
  if (x.contains('FOREIGN KEY')) return 'لا يمكن حفظ العملية لأن البيانات المرتبطة غير صحيحة.';
  return x.replaceAll('DatabaseException', 'خطأ في قاعدة البيانات');
}

/// ينفّذ عملية كتابة ويعرض للمستخدم رسالة مفهومة عند الفشل بدل تمرير الاستثناء.
Future<bool> runGuarded(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
    return false;
  }
}

String systemName(String? v) => switch (v) {
  'diesel' => 'ديزل',
  'solar' => 'شمسي',
  'equivalent_hybrid' => 'النوع الثالث',
  _ => 'غير محدد',
};
String statusName(Object? v) => switch ('$v') {
  'waiting' => 'منتظر',
  'postponed' => 'مؤجل',
  'running' => 'قيد التشغيل',
  'completed' => 'مكتمل',
  'new' => 'جديد',
  'under_review' => 'قيد المراجعة',
  'scheduled' => 'مجدول',
  'accepted' => 'مقبول',
  'notified' => 'تم الإبلاغ',
  'cancelled' => 'ملغى',
  'posted' => 'مرحل',
  _ => movementName('$v'),
};
String movementName(String v) =>
    {
      'receipt': 'شراء/إضافة',
      'delivery': 'تسليم',
      'advance': 'سلفة',
      'consumption': 'استهلاك',
      'correction': 'تصحيح جرد',
      'opening_balance': 'رصيد افتتاحي',
    }[v] ??
    v;
String paymentTypeName(String v) =>
    {
      'cash': 'نقدي',
      'check': 'شيك',
      'bank_transfer': 'تحويل بنكي',
      'wallet': 'محفظة',
      'other': 'أخرى',
    }[v] ??
    v;
String settingDisplay(String k, String v) => switch (k) {
  'system_type' => systemName(v),
  'queue_type' =>
    v == 'circular'
        ? 'طابور دائري'
        : v == 'booking'
        ? 'نظام حجز'
        : v,
  'time_source' =>
    v == 'server'
        ? 'وقت الخادم'
        : v == 'device'
        ? 'وقت الجهاز'
        : v,
  'partial_hour' => v == 'true' ? 'نعم' : 'لا',
  'manager_override_required' => v == 'true' ? 'نعم' : 'لا',
  'allow_midnight_crossing' => v == 'true' ? 'نعم' : 'لا',
  'sound_notifications' => v == 'true' ? 'نعم' : 'لا',
  'popup_notifications' => v == 'true' ? 'نعم' : 'لا',
  'reduced_motion' => v == 'true' ? 'نعم' : 'لا',
  'diesel_delivery_financial_credit' => v == 'true' ? 'نعم' : 'لا',
  _ => v,
};
String categoryName(String v) =>
    {
      'workers': 'عمال',
      'partners': 'شركاء',
      'fuel': 'وقود',
      'oil': 'زيت',
      'grease': 'شحم',
      'maintenance': 'صيانة',
      'parts': 'قطع غيار',
      'transport': 'نقل',
      'admin': 'إدارية',
      'other': 'أخرى',
    }[v] ??
    v;
String payTypeName(String v) =>
    {'fixed': 'راتب ثابت', 'hourly': 'بالساعة', 'percentage': 'نسبة'}[v] ?? v;
String targetName(String v) =>
    {'beneficiary': 'مستفيد', 'worker': 'عامل', 'partner': 'شريك'}[v] ?? v;

class SaqiaApp extends StatelessWidget {
  const SaqiaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    title: 'ساقية لإدارة محطة ضخ مياه الري',
    theme: SaqiaTheme.light(),
    darkTheme: SaqiaTheme.dark(),
    themeMode: ThemeMode.system,
    home: const AdminLoginPage(),
  );
}

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});
  @override
  State<AdminLoginPage> createState() => _LoginState();
}

class _LoginState extends State<AdminLoginPage> {
  final u = TextEditingController(text: 'admin'), p = TextEditingController();
  bool loading = false;
  String? error;
  Future<void> login() async {
    setState(() => loading = true);
    try {
      final user = await AdminService().authenticate(u.text.trim(), p.text);
      if (user == null) {
        setState(() => error = 'اسم المستخدم أو كلمة المرور غير صحيحة');
        return;
      }
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => AdminShell(
            role: '${user['role']}',
            userName: '${user['name']}',
            userId: user['id'] as int,
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) => Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 82,
                      height: 82,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: const LinearGradient(colors: [_blue, _cyan]),
                      ),
                      child: const Icon(
                        Icons.water_drop_rounded,
                        size: 46,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'ساقية لإدارة محطة ضخ مياه الري',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: u,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: p,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(c).colorScheme.error,
                          ),
                        ),
                      ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: loading ? null : login,
                        icon: const Icon(Icons.login),
                        label: loading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('تسجيل الدخول'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'في أول تشغيل: استخدم بيانات المدير الأولية ثم غيّر كلمة المرور.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class AdminShell extends StatefulWidget {
  final String role, userName;
  final int userId;
  const AdminShell({
    required this.role,
    required this.userName,
    required this.userId,
    super.key,
  });
  @override
  State<AdminShell> createState() => _ShellState();
}

class _ShellState extends State<AdminShell> {
  final repo = StationRepository();
  int index = 0;
  bool collapsed = false;
  Map<String, Object?> counts = {};
  String systemType = 'diesel';
  final menuSearch = TextEditingController();
  final pages = const [
    'لوحة التحكم',
    'المستفيدون',
    'سقاية جديدة',
    'السقايات',
    'جلسات السقي',
    'الطابور والحجوزات',
    'الديزل',
    'المدفوعات',
    'الصناديق والتحويلات',
    'المصروفات',
    'العمال',
    'الشركاء',
    'دفتر اليومية',
    'الأستاذ العام',
    'التقارير',
    'الإشعارات',
    'الإعدادات',
    'النسخ الاحتياطي',
    'قياس الأداء',
  ];
  AppRole get role => AppRole.values.firstWhere(
    (x) => x.name == widget.role,
    orElse: () => AppRole.operations,
  );
  Set<int> get visible {
    final s = <int>{0, 2, 4, 5, 6, 15};
    if (systemType == 'solar') s.remove(6);
    if (role == AppRole.manager || role == AppRole.accountant)
      s.addAll({1, 3, 7, 8, 9, 10, 11, 12, 13, 14});
    if (role == AppRole.manager) s.addAll({16, 17, 18});
    return s;
  }

  @override
  void initState() {
    super.initState();
    refreshCounts();
  }

  Future<void> refreshCounts() async {
    try {
      final x = await repo.dashboard();
      final cfg = await SystemConfig.load(repo);
      if (mounted) setState(() { counts = x; systemType = cfg.type; });
    } catch (_) {}
  }

  void go(int i) {
    if (visible.contains(i)) {
      setState(() => index = i);
      refreshCounts();
    }
  }

  @override
  Widget build(BuildContext c) {
    if (!visible.contains(index)) index = visible.first;
    final filter = menuSearch.text.trim();
    final menu = visible.where((i) => pages[i].contains(filter)).toList();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            pages[index],
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: refreshCounts,
              icon: const Icon(Icons.refresh),
            ),
            Builder(
              builder: (bc) => IconButton(
                tooltip: 'القائمة',
                onPressed: () => Scaffold.of(bc).openDrawer(),
                icon: const Icon(Icons.menu_open),
              ),
            ),
          ],
        ),
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(17),
                          gradient: const LinearGradient(
                            colors: [_blue, _purple],
                          ),
                        ),
                        child: const Icon(
                          Icons.water_drop,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'ساقية',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              widget.userName,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: TextField(
                    controller: menuSearch,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'بحث سريع في القائمة',
                      isDense: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Wrap(
                    spacing: 6,
                    children: [
                      _badge('الطابور', '${counts['queue'] ?? 0}', _purple),
                      _badge(
                        'التنبيهات',
                        '${counts['unread_notifications'] ?? 0}',
                        _cyan,
                      ),
                      _badge('حالة الرصيد', AccountingCalculations.balanceLabel((counts['remaining'] as num?)?.round() ?? 0), _green),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final i in menu)
                        ListTile(
                          selected: i == index,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          leading: Icon(_icon(i)),
                          title: Text(pages[i]),
                          trailing: i == 5
                              ? Text('${counts['queue'] ?? 0}')
                              : i == 15
                              ? Text('${counts['unread_notifications'] ?? 0}')
                              : null,
                          onTap: () {
                            Navigator.pop(c);
                            go(i);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _page(index, key: ValueKey(index)),
        ),
      ),
    );
  }

  Widget _badge(String a, String b, Color color) => Chip(
    avatar: CircleAvatar(
      backgroundColor: color,
      child: const SizedBox.shrink(),
    ),
    label: Text('$a: $b'),
  );
  IconData _icon(int i) => [
    Icons.dashboard_rounded,
    Icons.people_alt_rounded,
    Icons.add_circle_rounded,
    Icons.water_drop_rounded,
    Icons.timer_rounded,
    Icons.format_list_numbered_rounded,
    Icons.local_gas_station_rounded,
    Icons.payments_rounded,
    Icons.account_balance_rounded,
    Icons.receipt_long_rounded,
    Icons.engineering_rounded,
    Icons.groups_rounded,
    Icons.menu_book_rounded,
    Icons.account_tree_rounded,
    Icons.picture_as_pdf_rounded,
    Icons.notifications_rounded,
    Icons.settings_rounded,
    Icons.backup_rounded,
    Icons.speed_rounded,
  ][i];
  Widget _page(int i, {Key? key}) {
    final w = switch (i) {
      0 => DashboardPage(repo, onOpen: go),
      1 => BeneficiariesPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      2 => NewIrrigationPage(repo, manager: role == AppRole.manager),
      3 => IrrigationsPage(repo, manager: role == AppRole.manager),
      4 => SessionsPage(repo, userId: widget.userId),
      5 => QueueBookingPage(
        repo,
        userId: widget.userId,
        manager: role == AppRole.manager,
      ),
      6 => DieselPage(repo, userId: widget.userId),
      7 => PaymentsPage(repo, userId: widget.userId),
      8 => CashboxesPage(repo, userId: widget.userId),
      9 => ExpensesPage(repo, userId: widget.userId),
      10 => WorkersPage(repo, userId: widget.userId),
      11 => PartnersPage(repo, userId: widget.userId),
      12 => JournalPage(repo),
      13 => LedgerPage(repo),
      14 => ReportsPage(repo),
      15 => NotificationsPage(repo),
      16 => SettingsPage(repo, userId: widget.userId, onSystemTypeChanged: (v) => refreshCounts()),
      17 => BackupPage(repo),
      18 => PerformancePage(repo),
      _ => DashboardPage(repo, onOpen: go),
    };
    return KeyedSubtree(key: key, child: w);
  }
}

class PageFrame extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  final Widget child;
  const PageFrame({
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
    super.key,
  });
  @override
  Widget build(BuildContext c) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(c).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(child: child),
      ],
    ),
  );
}

class EmptyView extends StatelessWidget {
  final String text;
  const EmptyView(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.inbox_outlined,
          size: 52,
          color: Theme.of(c).colorScheme.outline,
        ),
        const SizedBox(height: 8),
        Text(text),
      ],
    ),
  );
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext c) =>
      const Center(child: CircularProgressIndicator());
}

class ErrorBox extends StatelessWidget {
  final String text;
  const ErrorBox(this.text, {super.key});
  @override
  Widget build(BuildContext c) => Center(
    child: Card(
      child: Padding(padding: const EdgeInsets.all(22), child: Text(text)),
    ),
  );
}

class DashboardPage extends StatefulWidget {
  final StationRepository r;
  final void Function(int) onOpen;
  const DashboardPage(this.r, {required this.onOpen, super.key});
  @override
  State<DashboardPage> createState() => _DashboardState();
}

class _DashboardState extends State<DashboardPage> {
  Map<String, Object?>? d;
  Map<String, Object?> session = {};
  double diesel = 0;
  Map<String, Object?>? warning;
  String systemType = 'diesel';
  bool loading = true;
  Future<void> load() async {
    try {
      final a = await widget.r.dashboard(),
          c = await widget.r.currentSession(),
          cfg = await SystemConfig.load(widget.r);
      final b = cfg.isDiesel ? await widget.r.dieselStock() : 0.0;
      final w = cfg.isDiesel ? await widget.r.dieselWarning() : <String, Object?>{};
      if (mounted)
        setState(() {
          d = a;
          diesel = b;
          session = c;
          warning = w;
          systemType = cfg.type;
          loading = false;
        });
    } catch (e) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Widget card(String title, String value, IconData icon, Color color) =>
      Container(
        width: 205,
        height: 116,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [color.withOpacity(.16), color.withOpacity(.04)],
          ),
          border: Border.all(color: color.withOpacity(.18)),
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const Spacer(),
            Text(title),
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      );
  @override
  Widget build(c) {
    if (loading) return const LoadingView();
    final remaining = (d?['remaining'] as num?)?.round() ?? 0;
    return PageFrame(
      title: 'لوحة التحكم',
      subtitle: 'ملخص تشغيلي ومالي مباشر من قاعدة البيانات',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث'),
        ),
      ],
      child: ListView(
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              card(
                'المستفيدون',
                '${d?['beneficiaries'] ?? 0}',
                Icons.people,
                _blue,
              ),
              card(
                'المنتظرون',
                '${d?['queue'] ?? 0}',
                Icons.format_list_numbered,
                _purple,
              ),
              card(
                'طلبات جديدة',
                '${d?['bookings'] ?? 0}',
                Icons.event_note,
                _cyan,
              ),
              card(
                'جلسات فعالة',
                '${d?['running_sessions'] ?? 0}',
                Icons.timer,
                _green,
              ),
              card('المستحق', money(d?['due']), Icons.request_quote, _blue),
              card('المدفوع', money(d?['paid']), Icons.payments, _green),
              card(
                'حالة أرصدة المستفيدين',
                AccountingCalculations.balanceLabel(remaining),
                Icons.account_balance_wallet,
                _purple,
              ),
              card(
                'المصروفات',
                money(d?['expenses']),
                Icons.receipt_long,
                _purple,
              ),
              if (systemType == 'diesel')
                card(
                  'رصيد الديزل',
                  '${diesel.toStringAsFixed(2)} لتر',
                  Icons.local_gas_station,
                  _cyan,
                ),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            child: ListTile(
              leading: Icon(
                session.isNotEmpty ? Icons.timer : Icons.timer_off,
                color: session.isNotEmpty ? _green : _blue,
              ),
              title: Text(
                session.isEmpty
                    ? 'لا توجد جلسة سقي حالية'
                    : 'جلسة السقي الحالية: ${session['beneficiary_name']}',
              ),
              subtitle: Text(
                session.isEmpty
                    ? 'المضخة متاحة'
                    : '${session['pump_name']} • بدأت ${session['actual_start']}',
              ),
              trailing: session.isEmpty
                  ? null
                  : FilledButton(
                      onPressed: () => widget.onOpen(4),
                      child: const Text('فتح الجلسة'),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: Icon(
                warning?['warning'] == true
                    ? Icons.warning_amber
                    : Icons.check_circle,
                color: warning?['warning'] == true
                    ? ['warning'] == true
                          ? Colors.orange
                          : _green
                    : _green,
              ),
              title: const Text('تنبيه الديزل'),
              subtitle: Text(
                '${diesel.toStringAsFixed(2)} لتر متاح من ${warning?['capacity'] ?? 0} لتر',
              ),
              trailing: warning?['warning'] == true
                  ? const Text('قريب من الحد')
                  : const Text('الحالة طبيعية'),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'وصول سريع',
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              QuickButton(
                'سقاية جديدة',
                Icons.water_drop,
                _blue,
                () => widget.onOpen(2),
              ),
              QuickButton(
                'قبض دفعة',
                Icons.payments,
                _green,
                () => widget.onOpen(7),
              ),
              QuickButton(
                'إضافة أو تسليم ديزل',
                Icons.local_gas_station,
                _cyan,
                () => widget.onOpen(6),
              ),
              QuickButton(
                'مصروف جديد',
                Icons.receipt_long,
                _purple,
                () => widget.onOpen(9),
              ),
              QuickButton(
                'جلسة سقي',
                Icons.timer,
                _purple,
                () => widget.onOpen(4),
              ),
              QuickButton(
                'التقارير',
                Icons.picture_as_pdf,
                _blue,
                () => widget.onOpen(14),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class QuickButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const QuickButton(this.text, this.icon, this.color, this.onTap, {super.key});
  @override
  Widget build(BuildContext c) => SizedBox(
    width: 190,
    child: FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, color: color),
      label: Text(text),
    ),
  );
}

class RecordDetailsPage extends StatefulWidget {
  final StationRepository r;
  final String kind;
  final int id;
  final String title;
  const RecordDetailsPage(
    this.r, {
    required this.kind,
    required this.id,
    required this.title,
    super.key,
  });
  @override
  State<RecordDetailsPage> createState() => _RecordDetailsState();
}

class _RecordDetailsState extends State<RecordDetailsPage> {
  Map<String, Object?> data = {};
  List<Map<String, Object?>> history = [];
  List<Map<String, Object?>> irrigations = [];
  Map<String, Object?> financial = {};
  bool loading = true;
  DateTime? filterFrom, filterTo;
  String paymentMovementFilter = 'all';
  DateTime? paymentFrom, paymentTo;
  List<Map<String, Object?>> paymentReceipts = [], paymentDisbursements = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  List<Map<String, Object?>> _paymentRows() {
    final all = [
      ...paymentReceipts.map((x) => {...x}),
      ...paymentDisbursements.map((x) => {...x}),
    ];
    return all.where((x) {
      final group = '${x['movement_group']}';
      if (paymentMovementFilter != 'all' && group != paymentMovementFilter) return false;
      final d = DateTime.tryParse('${x['date'] ?? ''}');
      if (paymentFrom != null && (d == null || d.isBefore(DateTime(paymentFrom!.year, paymentFrom!.month, paymentFrom!.day)))) return false;
      if (paymentTo != null && (d == null || d.isAfter(DateTime(paymentTo!.year, paymentTo!.month, paymentTo!.day, 23, 59, 59)))) return false;
      return true;
    }).toList()..sort((a,b) => '${b['date']}'.compareTo('${a['date']}'));
  }

  Future<void> pickPaymentDate(bool fromDate) async {
    final picked = await showDatePicker(
      context: context, firstDate: DateTime(2020), lastDate: DateTime(2100),
      initialDate: fromDate ? (paymentFrom ?? DateTime.now()) : (paymentTo ?? DateTime.now()),
      locale: const Locale('ar'),
    );
    if (picked == null || !mounted) return;
    setState(() { if (fromDate) paymentFrom = picked; else paymentTo = picked; });
  }

  Widget paymentMethodMovements(BuildContext c) {
    if (widget.kind != 'payment_method') return const SizedBox.shrink();
    final rows = _paymentRows();
    final receipts = rows.where((x) => x['movement_group'] == 'مقبوضات').toList();
    final disb = rows.where((x) => x['movement_group'] == 'مسلّمات').toList();
    final received = receipts.fold<int>(0, (s,x) => s + ((x['amount'] as num?)?.round() ?? 0));
    final delivered = disb.fold<int>(0, (s,x) => s + ((x['amount'] as num?)?.round() ?? 0));
    final scheme = Theme.of(c).colorScheme;
    Widget movementCard(Map<String,Object?> x) {
      final incoming = x['movement_group'] == 'مقبوضات';
      return Container(
        margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(.38),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: (incoming ? _green : _purple).withOpacity(.16)),
        ),
        child: Row(children: [
          Container(width: 40,height: 40,decoration: BoxDecoration(color:(incoming?_green:_purple).withOpacity(.12),borderRadius:BorderRadius.circular(12)),child:Icon(incoming?Icons.south_west_rounded:Icons.north_east_rounded,color:incoming?_green:_purple)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,children:[
            Text('${x['party_name'] ?? x['description'] ?? 'حركة'}',style:const TextStyle(fontWeight:FontWeight.w900)),
            const SizedBox(height:3), Text('${x['date'] ?? '-'} • ${x['notes'] ?? ''}',style:TextStyle(fontSize:12,color:scheme.onSurfaceVariant)),
          ])),
          Column(crossAxisAlignment:CrossAxisAlignment.end,children:[Text(money(x['amount']),style:const TextStyle(fontWeight:FontWeight.w900)),const SizedBox(height:3),Text(incoming?'مقبوضات':'مسلّمات',style:TextStyle(fontSize:12,color:incoming?_green:_purple))]),
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color:scheme.surface,borderRadius:BorderRadius.circular(26),border:Border.all(color:scheme.outlineVariant.withOpacity(.35))),
      child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Icon(Icons.swap_vert_rounded,color:scheme.primary),const SizedBox(width:10),const Expanded(child:Text('المسلّمات والمقبوضات',style:TextStyle(fontSize:18,fontWeight:FontWeight.w900))),Text('${rows.length} حركة',style:TextStyle(color:scheme.onSurfaceVariant))]),
        const SizedBox(height:12),
        Wrap(spacing:10,runSpacing:10,children:[
          metric(c,'إجمالي المقبوضات',money(received),Icons.south_west_rounded,_green),
          metric(c,'إجمالي المسلّمات',money(delivered),Icons.north_east_rounded,_purple),
          metric(c,'الصافي',money(received-delivered),Icons.account_balance_wallet_rounded,_blue),
        ]),
        const SizedBox(height:14),
        Wrap(spacing:8,runSpacing:8,children:[
          ChoiceChip(label:const Text('الكل'),selected:paymentMovementFilter=='all',onSelected:(_)=>setState(()=>paymentMovementFilter='all')),
          ChoiceChip(label:const Text('المقبوضات'),selected:paymentMovementFilter=='مقبوضات',onSelected:(_)=>setState(()=>paymentMovementFilter='مقبوضات')),
          ChoiceChip(label:const Text('المسلّمات'),selected:paymentMovementFilter=='مسلّمات',onSelected:(_)=>setState(()=>paymentMovementFilter='مسلّمات')),
          OutlinedButton.icon(onPressed:()=>pickPaymentDate(true),icon:const Icon(Icons.date_range),label:Text(paymentFrom==null?'من تاريخ':'من ${DateFormat('yyyy/MM/dd').format(paymentFrom!)}')),
          OutlinedButton.icon(onPressed:()=>pickPaymentDate(false),icon:const Icon(Icons.event),label:Text(paymentTo==null?'إلى تاريخ':'إلى ${DateFormat('yyyy/MM/dd').format(paymentTo!)}')),
        ]),
        const SizedBox(height:12),
        if (rows.isEmpty) const EmptyView('لا توجد حركة مطابقة للفلاتر') else Column(children:[for(final x in rows.take(200)) movementCard(x)]),
      ]),
    );
  }

  Future<void> load() async {
    try {
      late Map<String, Object?> d;
      List<Map<String, Object?>> h = [];
      switch (widget.kind) {
        case 'beneficiary':
          d = await widget.r.beneficiaryDetails(widget.id);
          h = await widget.r.beneficiaryStatement(widget.id);
          financial = await widget.r.partyFinancialSummary('beneficiary', widget.id);
          irrigations = await widget.r.partyIrrigations('beneficiary', widget.id);
          break;
        case 'worker':
          d = (await widget.r.db.query(
            'workers', where: 'id=?', whereArgs: [widget.id], limit: 1,
          )).first;
          h = await widget.r.workerTransactions(widget.id);
          financial = await widget.r.partyFinancialSummary('worker', widget.id);
          irrigations = await widget.r.partyIrrigations('worker', widget.id);
          break;
        case 'partner':
          d = (await widget.r.db.query(
            'partners', where: 'id=?', whereArgs: [widget.id], limit: 1,
          )).first;
          h = await widget.r.partnerTransactions(widget.id);
          financial = await widget.r.partyFinancialSummary('partner', widget.id);
          irrigations = await widget.r.partyIrrigations('partner', widget.id);
          break;
        case 'cashbox':
          d = (await widget.r.db.query(
            'cashboxes', where: 'id=?', whereArgs: [widget.id], limit: 1,
          )).first;
          h = await widget.r.db.query(
            'cashbox_transfers',
            where: 'from_cashbox_id=? OR to_cashbox_id=?',
            whereArgs: [widget.id, widget.id], orderBy: 'date DESC',
          );
          break;
        case 'payment_method':
          d = (await widget.r.db.query(
            'payment_methods', where: 'id=?', whereArgs: [widget.id], limit: 1,
          )).first;
          final receipts = await widget.r.db.query(
            '''SELECT p.id,p.date,p.amount,p.reference_number,p.notes,
                      COALESCE(b.name,w.name,pt.name,'غير محدد') party_name,
                      'مقبوضات' movement_group
               FROM payments p
               LEFT JOIN beneficiaries b ON b.id=p.beneficiary_id
               LEFT JOIN workers w ON w.id=p.worker_id
               LEFT JOIN partners pt ON pt.id=p.partner_id
               WHERE p.payment_method_id=? AND p.status='posted'
               ORDER BY p.date DESC,p.id DESC''', args: [widget.id]);
          final disbursements = await widget.r.db.query(
            '''SELECT e.id,e.date,e.amount,e.title description,e.notes,
                      COALESCE(e.title,'مصروف') party_name,
                      'مسلّمات' movement_group
               FROM expenses e
               WHERE e.payment_method_id=? AND e.status='posted'
               ORDER BY e.date DESC,e.id DESC''', args: [widget.id]);
          paymentReceipts = receipts;
          paymentDisbursements = disbursements;
          h = [
            ...receipts.map((x) => <String, Object?>{...x}),
            ...disbursements.map((x) => <String, Object?>{...x}),
          ]..sort((a,b) => '${b['date']}'.compareTo('${a['date']}'));
          break;
        case 'queue':
          d = (await widget.r.db.query(
            "SELECT q.*, b.name beneficiary_name FROM queue_entries q JOIN beneficiaries b ON b.id=q.beneficiary_id WHERE q.id=?",
            args: [widget.id],
          )).first;
          h = await widget.r.db.query(
            'audit_logs', where: "record_id=? AND table_name='queue_entries'",
            whereArgs: [widget.id], orderBy: 'created_at DESC',
          );
          break;
        case 'booking':
          d = (await widget.r.db.query(
            "SELECT b.*, x.name beneficiary_name FROM booking_requests b JOIN beneficiaries x ON x.id=b.beneficiary_id WHERE b.id=?",
            args: [widget.id],
          )).first;
          h = await widget.r.db.query(
            'audit_logs', where: "record_id=? AND table_name='booking_requests'",
            whereArgs: [widget.id], orderBy: 'created_at DESC',
          );
          break;
        case 'journal':
          d = (await widget.r.db.query(
            'journal_entries', where: 'id=?', whereArgs: [widget.id], limit: 1,
          )).first;
          h = await widget.r.db.query(
            'journal_lines', where: 'journal_entry_id=?', whereArgs: [widget.id],
          );
          break;
        default:
          d = {};
      }
      if (mounted) {
        setState(() {
          data = d;
          history = h;
          if (financial.isEmpty) financial = {};
          this.irrigations = irrigations;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  String label(String k) => {
    'name': 'الاسم', 'phone': 'الهاتف', 'jerba_number': 'رقم الجربة',
    'address': 'العنوان', 'location': 'الموقع', 'opening_balance': 'الرصيد الافتتاحي',
    'carried_balance': 'الرصيد المرحل', 'pay_type': 'طريقة الاستحقاق',
    'fixed_salary': 'الراتب الثابت', 'hourly_rate': 'أجر الساعة',
    'percentage_rate': 'النسبة', 'ownership_mode': 'طريقة الملكية',
    'ownership_percentage': 'نسبة الملكية', 'shares_count': 'عدد الحصص',
    'current_balance': 'الرصيد الحالي', 'account_number': 'رقم الحساب',
    'bank_name': 'اسم البنك', 'type': 'النوع', 'position': 'الترتيب',
    'status': 'الحالة', 'created_at': 'تاريخ الإنشاء', 'date': 'التاريخ',
    'amount': 'المبلغ', 'notes': 'الملاحظات', 'description': 'البيان',
    'reference_number': 'المرجع', 'debit': 'المدين', 'credit': 'الدائن',
    'memo': 'المذكرة', 'beneficiary_name': 'المستفيد', 'scheduled_start': 'بداية الموعد',
    'scheduled_end': 'نهاية الموعد', 'cancel_reason': 'سبب الإلغاء',
    'postponed_count': 'مرات التأجيل', 'created_by': 'أنشأ بواسطة',
  }[k] ?? k.replaceAll('_', ' ');

  String displayValue(String k, Object? v) {
    if (v == null || v.toString().trim().isEmpty) return '-';
    if (k == 'ownership_percentage' || k == 'percentage_rate') return '${v}%';
    if (k == 'shares_count' || k == 'position' || k == 'postponed_count') return '$v';
    if (['opening_balance', 'carried_balance', 'fixed_salary', 'hourly_rate',
      'current_balance', 'amount', 'debit', 'credit'].contains(k)) return money(v);
    if (k == 'pay_type') return payTypeName('$v');
    if (k == 'ownership_mode') return '$v' == 'percentage' ? 'نسبة ملكية' : 'عدد حصص';
    if (k == 'type') return statusName(v);
    if (k == 'status') return statusName(v);
    return '$v';
  }

  String primaryName() =>
      '${data['name'] ?? data['beneficiary_name'] ?? data['description'] ?? widget.title}';

  String kindCaption() => {
    'beneficiary': 'ملف المستفيد وكشف الحساب',
    'worker': 'ملف العامل وحركات الاستحقاق والدفع',
    'partner': 'ملف الشريك وحركات حصته',
    'cashbox': 'الرصيد وحركة التحويلات',
    'payment_method': 'بيانات طريقة الدفع وحركاتها',
    'queue': 'حالة الدور وسجل الإجراءات',
    'booking': 'تفاصيل الطلب وسجل المراجعة',
    'journal': 'القيد المحاسبي وقيوده التفصيلية',
  }[widget.kind] ?? 'تفاصيل السجل';

  IconData kindIcon() => {
    'beneficiary': Icons.agriculture_rounded,
    'worker': Icons.engineering_rounded,
    'partner': Icons.handshake_rounded,
    'cashbox': Icons.account_balance_wallet_rounded,
    'payment_method': Icons.payments_rounded,
    'queue': Icons.format_list_numbered_rounded,
    'booking': Icons.event_available_rounded,
    'journal': Icons.receipt_long_rounded,
  }[widget.kind] ?? Icons.description_rounded;

  List<MapEntry<String, Object?>> fieldsFor(List<String> keys) => keys
      .where((k) => data[k] != null && data[k].toString().trim().isNotEmpty)
      .map((k) => MapEntry(k, data[k]))
      .toList();

  Widget fieldTile(BuildContext c, String k, Object? v) {
    final scheme = Theme.of(c).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(.48),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withOpacity(.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label(k), style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(displayValue(k, v), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Widget section(BuildContext c, String title, IconData icon, List<MapEntry<String, Object?>> fields) {
    if (fields.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(c).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Theme.of(c).colorScheme.outlineVariant.withOpacity(.35)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.045), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: Theme.of(c).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, color: Theme.of(c).colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (_, box) {
            final columns = box.maxWidth >= 1050 ? 4 : box.maxWidth >= 700 ? 3 : box.maxWidth >= 430 ? 2 : 1;
            final gap = 10.0;
            final width = (box.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap, runSpacing: gap,
              children: [for (final f in fields) SizedBox(width: width, child: fieldTile(c, f.key, f.value))],
            );
          }),
        ],
      ),
    );
  }

  Widget metric(BuildContext c, String title, String value, IconData icon, Color color) =>
      Container(
          constraints: const BoxConstraints(minWidth: 170),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight, end: Alignment.bottomLeft,
              colors: [color.withOpacity(.18), color.withOpacity(.055)],
            ),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: color.withOpacity(.18)),
          ),
          child: Row(children: [
            Icon(icon, color: color, size: 28), const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant, fontSize: 12)),
              const SizedBox(height: 3),
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            ])),
          ]),
      );

  Widget historyView(BuildContext c) {
    if (history.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: Theme.of(c).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Column(children: [
          Icon(Icons.timeline_rounded, size: 42), SizedBox(height: 8),
          Text('لا توجد حركات مرتبطة بهذا السجل'),
        ]),
      );
    }
    return Column(children: [
      for (int i = 0; i < history.length && i < 100; i++)
        _TimelineItem(
          first: i == 0,
          last: i == history.length - 1 || i == 99,
          title: _historyTitle(history[i]),
          subtitle: _historySub(history[i]),
          amount: _historyAmount(history[i]),
        ),
    ]);
  }

  String balanceText(Object? v) => AccountingCalculations.balanceLabel((v as num?)?.round() ?? 0);

  Future<void> pickDetailDate(bool fromDate) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020), lastDate: DateTime(2100),
      initialDate: fromDate ? (filterFrom ?? DateTime.now()) : (filterTo ?? DateTime.now()),
      locale: const Locale('ar'),
    );
    if (!mounted || picked == null) return;
    setState(() { if (fromDate) filterFrom = picked; else filterTo = picked; });
  }

  List<Map<String,Object?>> filteredIrrigations() => irrigations.where((x) {
    final d = DateTime.tryParse('${x['date'] ?? x['start_datetime'] ?? ''}');
    if (d == null) return true;
    if (filterFrom != null && d.isBefore(DateTime(filterFrom!.year, filterFrom!.month, filterFrom!.day))) return false;
    if (filterTo != null && d.isAfter(DateTime(filterTo!.year, filterTo!.month, filterTo!.day, 23, 59, 59))) return false;
    return true;
  }).toList();

  Future<void> printPersonReport() async {
    final key = widget.kind == 'worker' ? 'worker_transactions' : widget.kind == 'partner' ? 'partner_accounts' : 'beneficiary_detailed';
    try {
      await ReportService(widget.r).printPdf(key, from: filterFrom, to: filterTo,
        beneficiaryId: widget.kind == 'beneficiary' ? widget.id : null,
        workerId: widget.kind == 'worker' ? widget.id : null,
        partnerId: widget.kind == 'partner' ? widget.id : null,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تصدير التقرير: $e')));
    }
  }

  Widget financialPanel(BuildContext c) {
    if (!['beneficiary','worker','partner'].contains(widget.kind)) return const SizedBox.shrink();
    final minutes = (financial['irrigation_minutes'] as num?)?.round() ?? 0;
    final total = (financial['irrigation_total'] as num?)?.round() ?? 0;
    final earnings = (financial['earnings'] as num?)?.round() ?? 0;
    final paid = (financial['paid'] as num?)?.round() ?? 0;
    final balance = (financial['balance'] as num?)?.round() ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft,
          colors: [Theme.of(c).colorScheme.primaryContainer.withOpacity(.7), Theme.of(c).colorScheme.surface]),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Theme.of(c).colorScheme.outlineVariant.withOpacity(.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.insights_rounded, color: Theme.of(c).colorScheme.primary), const SizedBox(width: 10),
          const Text('الملخص المالي والإحصائي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))]),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (_, box) {
          final n = box.maxWidth >= 950 ? 5 : box.maxWidth >= 650 ? 3 : 2;
          final gap = 10.0; final w = (box.maxWidth - gap*(n-1))/n;
          final items = <Widget>[
            metric(c, 'استهلاك السقايات', '$minutes دقيقة', Icons.timer_outlined, _cyan),
            metric(c, 'إجمالي السقايات', money(total), Icons.water_drop_outlined, _blue),
            if (widget.kind != 'beneficiary') metric(c, 'الاستحقاقات/الأرباح', money(earnings), Icons.trending_up_rounded, _purple),
            metric(c, 'الدفعات المسددة', money(paid), Icons.payments_outlined, _green),
            metric(c, 'حالة الرصيد', balanceText(balance), Icons.account_balance_wallet_outlined, balance > 0 ? Colors.red : _green),
          ];
          return Wrap(spacing: gap, runSpacing: gap, children: [for (final item in items) SizedBox(width: w, child: item)]);
        }),
      ]),
    );
  }

  Widget irrigationTable(BuildContext c) {
    final rows = filteredIrrigations();
    return Container(
      margin: const EdgeInsets.only(bottom: 16), padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Theme.of(c).colorScheme.surface, borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Theme.of(c).colorScheme.outlineVariant.withOpacity(.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.water_drop_rounded, color: _cyan), const SizedBox(width: 10),
          const Expanded(child: Text('السقايات المرتبطة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
          OutlinedButton.icon(onPressed: () => pickDetailDate(true), icon: const Icon(Icons.date_range), label: Text(filterFrom == null ? 'من تاريخ' : '${filterFrom!.day}/${filterFrom!.month}/${filterFrom!.year}')),
          const SizedBox(width: 6),
          OutlinedButton.icon(onPressed: () => pickDetailDate(false), icon: const Icon(Icons.event), label: Text(filterTo == null ? 'إلى تاريخ' : '${filterTo!.day}/${filterTo!.month}/${filterTo!.year}')),
        ]),
        const SizedBox(height: 12),
        if (rows.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('لا توجد سقايات ضمن الفلتر الحالي')))
        else SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          columns: const [DataColumn(label: Text('اليوم')), DataColumn(label: Text('التاريخ')), DataColumn(label: Text('التفاصيل')), DataColumn(label: Text('المدة')), DataColumn(label: Text('المستحق')), DataColumn(label: Text('المدفوع'))],
          rows: [for (final x in rows) DataRow(cells: [
            DataCell(Text(DateFormat('EEEE','ar').format(DateTime.tryParse('${x['date']}') ?? DateTime.now()))),
            DataCell(Text('${x['date'] ?? '-'}'.split('T').first)),
            DataCell(Text('${systemName('${x['system_type']}')} • ${x['notes'] ?? 'جلسة سقي'}')),
            DataCell(Text('${x['minutes'] ?? 0} دقيقة')),
            DataCell(Text(money(x['total_amount']))),
            DataCell(Text(money(x['paid_amount']))),
          ])],
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext c) {
    if (loading) return const LoadingView();
    if (data.isEmpty) return Scaffold(appBar: AppBar(title: Text(widget.title)), body: const ErrorBox('تعذر العثور على السجل'));

    final name = primaryName();
    final balance = (data['balance'] is Map) ? ((data['balance'] as Map)['balance'] as num?)?.round() : null;
    final current = (data['current_balance'] as num?)?.round();
    final debit = (data['debit'] as num?)?.round();
    final credit = (data['credit'] as num?)?.round();

    final basic = fieldsFor(['name', 'phone', 'jerba_number', 'address', 'location', 'beneficiary_name', 'account_number', 'bank_name', 'type', 'status']);
    final accounting = fieldsFor(['opening_balance', 'carried_balance', 'fixed_salary', 'hourly_rate', 'percentage_rate', 'ownership_mode', 'ownership_percentage', 'shares_count', 'current_balance', 'position', 'postponed_count']);
    final meta = fieldsFor(['date', 'created_at', 'scheduled_start', 'scheduled_end', 'reference_number', 'description', 'memo', 'notes', 'cancel_reason']);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(c).scaffoldBackgroundColor,
        appBar: AppBar(
          title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w900)),
          actions: [
            if (['beneficiary','worker','partner'].contains(widget.kind)) IconButton(onPressed: printPersonReport, tooltip: 'تصدير التقرير', icon: const Icon(Icons.picture_as_pdf_rounded)),
            IconButton(onPressed: load, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded)),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 32),
          children: [
            financialPanel(c),
            if (['beneficiary','worker','partner'].contains(widget.kind)) irrigationTable(c),
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight, end: Alignment.bottomLeft,
                  colors: [Theme.of(c).colorScheme.primaryContainer, Theme.of(c).colorScheme.surface],
                ),
                borderRadius: BorderRadius.circular(30),
                border: Border.all(color: Theme.of(c).colorScheme.primary.withOpacity(.14)),
              ),
              child: Row(children: [
                Container(
                  width: 70, height: 70,
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.primary,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [BoxShadow(color: Theme.of(c).colorScheme.primary.withOpacity(.25), blurRadius: 22, offset: const Offset(0, 9))],
                  ),
                  child: Icon(kindIcon(), color: Theme.of(c).colorScheme.onPrimary, size: 34),
                ),
                const SizedBox(width: 17),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(kindCaption(), style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant)),
                ])),
                if (data['status'] != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: Theme.of(c).colorScheme.surface, borderRadius: BorderRadius.circular(30)),
                    child: Text(statusName(data['status']), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            if (balance != null || current != null || debit != null || credit != null)
              LayoutBuilder(builder: (_, box) {
                final items = <Widget>[];
                if (balance != null) items.add(metric(c, 'الرصيد', AccountingCalculations.balanceLabel(balance), Icons.account_balance_rounded, balance > 0 ? Colors.redAccent : _green));
                if (current != null) items.add(metric(c, 'الرصيد الحالي', money(current), Icons.account_balance_wallet_rounded, _blue));
                if (debit != null) items.add(metric(c, 'المدين', money(debit), Icons.arrow_downward_rounded, _purple));
                if (credit != null) items.add(metric(c, 'الدائن', money(credit), Icons.arrow_upward_rounded, _green));
                if (items.isEmpty) return const SizedBox.shrink();
                if (box.maxWidth < 700) return Wrap(spacing: 10, runSpacing: 10, children: items.map((x) => SizedBox(width: box.maxWidth, child: x)).toList());
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (int i=0;i<items.length;i++) ...[if(i>0) const SizedBox(width:10), Expanded(child: items[i])]]);
              }),
            const SizedBox(height: 16),
            section(c, 'البيانات الأساسية', Icons.badge_rounded, basic),
            section(c, 'الأرصدة والاستحقاقات', Icons.account_balance_rounded, accounting),
            section(c, 'معلومات السجل', Icons.info_outline_rounded, meta),
            paymentMethodMovements(c),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(c).colorScheme.surface,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Theme.of(c).colorScheme.outlineVariant.withOpacity(.35)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 40, height: 40, decoration: BoxDecoration(color: Theme.of(c).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(13)), child: Icon(Icons.timeline_rounded, color: Theme.of(c).colorScheme.secondary)),
                  const SizedBox(width: 12),
                  const Text('السجل الزمني', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 16),
                historyView(c),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  String _historyTitle(Map<String, Object?> x) => '${x['description'] ?? x['type'] ?? x['title'] ?? 'حركة'}';
  String _historySub(Map<String, Object?> x) => '${x['date'] ?? x['created_at'] ?? '-'} • ${x['notes'] ?? x['memo'] ?? x['status'] ?? ''}';
  String _historyAmount(Map<String, Object?> x) {
    final v = x['amount'] ?? x['debit'] ?? x['credit'];
    return v == null ? '' : money(v);
  }
}

class _TimelineItem extends StatelessWidget {
  final bool first, last;
  final String title, subtitle, amount;
  const _TimelineItem({required this.first, required this.last, required this.title, required this.subtitle, required this.amount});
  @override
  Widget build(BuildContext c) => IntrinsicHeight(
    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 30, child: Column(children: [
        if (!first) Expanded(child: Container(width: 2, color: Theme.of(c).colorScheme.outlineVariant)),
        Container(width: 12, height: 12, decoration: BoxDecoration(color: Theme.of(c).colorScheme.primary, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Theme.of(c).colorScheme.primary.withOpacity(.25), blurRadius: 8)])),
        if (!last) Expanded(child: Container(width: 2, color: Theme.of(c).colorScheme.outlineVariant)),
      ])),
      const SizedBox(width: 8),
      Expanded(child: Container(
        margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Theme.of(c).colorScheme.surfaceContainerHighest.withOpacity(.38), borderRadius: BorderRadius.circular(17)),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 3), Text(subtitle, style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.onSurfaceVariant))])),
          if (amount.isNotEmpty) Text(amount, style: const TextStyle(fontWeight: FontWeight.w900)),
        ]),
      )),
    ]),
  );
}

class BeneficiariesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const BeneficiariesPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<BeneficiariesPage> createState() => _BeneficiariesState();
}

class _BeneficiariesState extends State<BeneficiariesPage> {
  final q = TextEditingController();
  List<Map<String, Object?>> rows = [];
  bool loading = true;
  Future<void> load() async {
    setState(() => loading = true);
    try {
      final x = await widget.r.beneficiaries(q.text.trim());
      if (mounted) setState(() => rows = x);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(),
        p = TextEditingController(),
        j = TextEditingController(),
        a = TextEditingController(),
        l = TextEditingController(),
        o = TextEditingController(text: '0'),
        c = TextEditingController(text: '0');
    bool needy = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'إضافة مستفيد',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(
              labelText: 'اسم المستفيد *',
              hintText: 'الاسم الكامل',
            ),
          ),
          TextField(
            controller: p,
            decoration: const InputDecoration(
              labelText: 'رقم الهاتف',
              hintText: 'رقم التواصل',
            ),
          ),
          TextField(
            controller: j,
            decoration: const InputDecoration(labelText: 'رقم الجربة'),
          ),
          TextField(
            controller: a,
            decoration: const InputDecoration(labelText: 'العنوان'),
          ),
          TextField(
            controller: l,
            decoration: const InputDecoration(labelText: 'الموقع'),
          ),
          TextField(
            controller: o,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد المرحل'),
          ),
          StatefulBuilder(
            builder: (c, s) => CheckboxListTile(
              value: needy,
              onChanged: (v) => s(() => needy = v ?? false),
              title: const Text('مستفيد من فئة المحتاجين'),
            ),
          ),
        ],
        onSave: () => Navigator.pop(context, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.createBeneficiary(
        name: n.text,
        phone: p.text,
        jerba: j.text,
        address: a.text,
        location: l.text,
        needy: needy,
        opening: int.tryParse(o.text) ?? 0,
        carried: int.tryParse(c.text) ?? 0,
        userId: widget.userId,
      ))) return;
      await load();
    }
  }

  Future<void> edit(Map<String, Object?> x) async {
    final n = TextEditingController(text: '${x['name']}'),
        p = TextEditingController(text: '${x['phone'] ?? ''}'),
        j = TextEditingController(text: '${x['jerba_number'] ?? ''}'),
        a = TextEditingController(text: '${x['address'] ?? ''}'),
        o = TextEditingController(text: '${x['opening_balance'] ?? 0}'),
        c = TextEditingController(text: '${x['carried_balance'] ?? 0}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تعديل بيانات المستفيد',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(labelText: 'الاسم'),
          ),
          TextField(
            controller: p,
            decoration: const InputDecoration(labelText: 'الهاتف'),
          ),
          TextField(
            controller: j,
            decoration: const InputDecoration(labelText: 'رقم الجربة'),
          ),
          TextField(
            controller: a,
            decoration: const InputDecoration(labelText: 'العنوان'),
          ),
          TextField(
            controller: o,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد المرحل'),
          ),
        ],
        onSave: () => Navigator.pop(context, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.updateBeneficiary(x['id'] as int, {
        'name': n.text.trim(),
        'phone': p.text,
        'jerba_number': j.text,
        'address': a.text,
        'opening_balance': int.tryParse(o.text) ?? 0,
        'carried_balance': int.tryParse(c.text) ?? 0,
      }, widget.userId))) return;
      await load();
    }
  }

  Future<void> remove(Map<String, Object?> x) async {
    final r = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'حذف منطقي للمستفيد',
        children: [
          const Text(
            'لن تُحذف السجلات المحاسبية، وسيتم إخفاء المستفيد من القوائم النشطة.',
          ),
          TextField(
            controller: r,
            decoration: const InputDecoration(labelText: 'سبب الحذف *'),
          ),
        ],
        onSave: () => Navigator.pop(context, r.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.deleteBeneficiary(x['id'] as int, widget.userId, r.text))) return;
      await load();
    }
  }

  Future<void> details(Map<String, Object?> x) async {
    final loaded = await widget.r.beneficiaryDetails(x['id'] as int);
    if (loaded.isEmpty || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordDetailsPage(
          widget.r,
          kind: 'beneficiary',
          id: x['id'] as int,
          title: 'تفاصيل المستفيد',
        ),
      ),
    );
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المستفيدون',
    subtitle: 'بحث سريع وإدارة البيانات والأرصدة وكشف الحساب',
    actions: [
      OutlinedButton.icon(onPressed: () => ReportService(widget.r).printPdf('beneficiary_list'), icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('تقرير المستفيدين')),
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.person_add),
        label: const Text('إضافة مستفيد'),
      ),
    ],
    child: Column(
      children: [
        TextField(
          controller: q,
          onChanged: (_) => load(),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث بالاسم أو الهاتف أو رقم الجربة أو الموقع',
            hintText: 'اكتب جزءًا من الاسم أو الرقم',
          ),
        ),
        const SizedBox(height: 10),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: rows.isEmpty && !loading
              ? const EmptyView('لا توجد بيانات مطابقة')
              : LayoutBuilder(builder: (_, box) {
                  final cols = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 720 ? 2 : 1;
                  final gap = 12.0;
                  final width = (box.maxWidth - gap * (cols - 1)) / cols;
                  return SingleChildScrollView(
                    child: Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: rows.map((x) {
                        final balance = (x['balance'] as num?)?.round() ?? 0;
                        return SizedBox(
                          width: width,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(24),
                            onTap: () => details(x),
                            onLongPress: () => showModalBottomSheet<void>(
                              context: context,
                              showDragHandle: true,
                              builder: (bc) => SafeArea(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    ListTile(
                                      leading: const Icon(Icons.edit_outlined),
                                      title: const Text('تعديل معلومات المستخدم'),
                                      onTap: () {
                                        Navigator.pop(bc);
                                        edit(x);
                                      },
                                    ),
                                    if (widget.manager)
                                      ListTile(
                                        leading: const Icon(Icons.delete_outline, color: Colors.red),
                                        title: const Text('حذف'),
                                        onTap: () {
                                          Navigator.pop(bc);
                                          remove(x);
                                        },
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const CircleAvatar(child: Icon(Icons.agriculture_rounded)),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            '${x['name']}',
                                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                                          ),
                                        ),
                                        PopupMenuButton<String>(
                                          onSelected: (v) {
                                            if (v == 'edit') edit(x);
                                            if (v == 'delete' && widget.manager) remove(x);
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(value: 'edit', child: Text('تعديل معلومات المستخدم')),
                                            PopupMenuItem(value: 'delete', child: Text('حذف')),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      '${x['phone'] ?? 'بدون هاتف'} • ${x['jerba_number'] ?? 'بدون رقم جربة'}',
                                      style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      AccountingCalculations.balanceLabel(balance),
                                      style: TextStyle(fontWeight: FontWeight.w900, color: balance > 0 ? Colors.red : _green),
                                    ),
                                    const SizedBox(height: 10),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: OutlinedButton.icon(
                                        onPressed: () => details(x),
                                        icon: const Icon(Icons.open_in_new),
                                        label: const Text('التفاصيل'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  );
                }),
        ),
      ],
    ),
  );
}

class NewIrrigationPage extends StatefulWidget {
  final StationRepository r;
  final bool manager;
  const NewIrrigationPage(this.r, {required this.manager, super.key});
  @override
  State<NewIrrigationPage> createState() => _NewIrrigationState();
}

class _NewIrrigationState extends State<NewIrrigationPage> {
  List<Map<String, Object?>> beneficiaries = [],
      workers = [],
      partners = [],
      pumps = [],
      queue = [],
      bookings = [],
      sessions = [],
      history = [];
  int? bid, workerId, partnerId, pumpId, queueId, bookingId, sessionId;
  String partyType = 'beneficiary', type = 'diesel', queueType = 'circular', search = '';
  DateTime start = DateTime.now(),
      end = DateTime.now().add(const Duration(hours: 1));
  final paid = TextEditingController(text: '0'),
      reason = TextEditingController();
  final List<Map<String, DateTime>> cloudPeriods = [];
  bool managerOverride = false,
      loading = true,
      saved = false,
      useSession = false;
  double beneficiaryDiesel = 0;
  Map<String, String> settings = {};
  List<Map<String, Object?>> methods = [];
  int? payMethod;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final b = await widget.r.beneficiaries(),
        w = await widget.r.workers(),
        pt = await widget.r.partners(),
        p = await widget.r.db.query('pumps', where: 'active=1', orderBy: 'id'),
        q = await widget.r.queue(),
        bk = await widget.r.bookings(),
        ss = await widget.r.sessions(),
        st = await widget.r.settings(),
        pm = await widget.r.paymentMethods();
    if (mounted)
      setState(() {
        methods = pm;
        final cashM = pm.where((x) => x['type'] == 'cash').toList();
        payMethod = (cashM.isNotEmpty ? cashM.first : (pm.isNotEmpty ? pm.first : null))?['id'] as int?;
        beneficiaries = b;
        workers = w;
        partners = pt;
        pumps = p;
        queue = q;
        bookings = bk;
        sessions = ss;
        settings = st;
        queueType = st['queue_type'] ?? 'circular';
        if (b.isNotEmpty) bid = b.first['id'] as int;
        final configured = int.tryParse(st['selected_pump_id'] ?? '');
        final chosen = p.where((x) => x['id'] == configured).toList();
        if (chosen.isNotEmpty) pumpId = chosen.first['id'] as int;
        type = st['system_type'] ?? 'diesel';
        loading = false;
      });
    if (bid != null) await selectBeneficiary(bid!);
  }

  Future<void> selectBeneficiary(int id) async {
    final h = await widget.r.irrigations(beneficiaryId: id);
    final d = await widget.r.db.query(
      "SELECT COALESCE(b.opening_diesel_liters, 0)+COALESCE(b.carried_diesel_liters,0)+COALESCE((SELECT SUM(liters) FROM diesel_movements WHERE beneficiary_id=? AND kind IN ('delivery','advance')),0)-COALESCE((SELECT SUM(liters) FROM diesel_movements WHERE beneficiary_id=? AND kind='consumption'),0) stock FROM beneficiaries b WHERE b.id=?",
      args: [id, id, id],
    );
    if (!mounted) return;
    setState(() {
      bid = id;
      history = h;
      beneficiaryDiesel = d.isEmpty
          ? 0
          : (d.first['stock'] as num?)?.toDouble() ?? 0;
    });
  }

  int get minutes => end.difference(start).inMinutes;
  int get cloudMin => cloudPeriods.fold<int>(0, (sum, p) => sum + p['end']!.difference(p['start']!).inMinutes);
  int get waterRate =>
      int.tryParse(settings['diesel_hourly_water_rate'] ?? '0') ?? 0;
  double get liters =>
      double.tryParse(settings['diesel_liters_per_hour'] ?? '0') ?? 0;
  int get dieselPrice =>
      int.tryParse(settings['diesel_price_per_liter'] ?? '0') ?? 0;
  int get solarRate => int.tryParse(settings['solar_hourly_rate'] ?? '0') ?? 0;
  int get thirdRate =>
      int.tryParse(settings['third_type_hourly_rate'] ?? '0') ?? 0;
  Map<String, num> preview() {
    if (minutes <= 0)
      return {
        'الإجمالي': 0,
        'المياه': 0,
        'الديزل': 0,
        'القابل للمحاسبة': 0,
        'المدفوع': 0,
        'حالة الرصيد': 0,
      };
    final c = type == 'diesel'
        ? AccountingCalculations.diesel(
            start: start,
            end: end,
            hourlyWaterRate: waterRate,
            litersPerHour: liters,
            dieselPrice: dieselPrice,
            cloudMinutes: 0,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          )
        : type == 'solar'
        ? AccountingCalculations.solar(
            start: start,
            end: end,
            hourlyRate: solarRate,
            cloudMinutes: cloudMin,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          )
        : AccountingCalculations.equivalent(
            start: start,
            end: end,
            hourlyRate: thirdRate,
            allowMidnightCrossing:
                settings['allow_midnight_crossing'] == 'true',
            rounding: settings['rounding'] ?? 'nearest',
            partialHour: settings['partial_hour'] != 'false',
          );
    final paidValue = int.tryParse(paid.text) ?? 0;
    return {
      'الإجمالي': c.totalAmount,
      'المياه': c.waterAmount,
      'الديزل': c.dieselAmount,
      'القابل للمحاسبة': c.chargeableMinutes,
      'المدفوع': paidValue,
      'حالة الرصيد': c.totalAmount - paidValue,
    };
  }

  bool _cloudPeriodValid(DateTime cloudStart, DateTime cloudEnd, {int? editingIndex}) {
    if (!cloudEnd.isAfter(cloudStart)) {
      msg('وقت نهاية الغيم يجب أن يكون بعد وقت بدايته');
      return false;
    }
    if (cloudStart.isBefore(start) || cloudEnd.isAfter(end)) {
      msg('فترة الغيم يجب أن تكون داخل وقت السقاية');
      return false;
    }
    for (var i = 0; i < cloudPeriods.length; i++) {
      if (editingIndex != null && i == editingIndex) continue;
      final a = cloudPeriods[i]['start']!;
      final b = cloudPeriods[i]['end']!;
      if (cloudStart.isBefore(b) && cloudEnd.isAfter(a)) {
        msg('فترة الغيم تتداخل مع فترة غيم أخرى');
        return false;
      }
    }
    final total = cloudMin - (editingIndex == null ? 0 : cloudPeriods[editingIndex]['end']!.difference(cloudPeriods[editingIndex]['start']!).inMinutes) + cloudEnd.difference(cloudStart).inMinutes;
    if (total > minutes) {
      msg('إجمالي خصم الغيم لا يمكن أن يتجاوز مدة السقاية');
      return false;
    }
    return true;
  }

  Future<void> addCloudPeriod({int? editingIndex}) async {
    if (type != 'solar') return;
    final existing = editingIndex == null ? null : cloudPeriods[editingIndex];
    final initialStart = existing?['start'] ?? start;
    final initialEnd = existing?['end'] ?? start.add(const Duration(minutes: 15));
    final ts = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initialStart), helpText: 'بداية الغيم');
    if (ts == null) return;
    final te = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initialEnd), helpText: 'نهاية الغيم');
    if (te == null) return;
    final startMinutes = ts.hour * 60 + ts.minute;
    final endMinutes = te.hour * 60 + te.minute;
    final cs = DateTime(start.year, start.month, start.day, ts.hour, ts.minute);
    final ce = DateTime(start.year, start.month, start.day + (endMinutes <= startMinutes ? 1 : 0), te.hour, te.minute);
    if (!_cloudPeriodValid(cs, ce, editingIndex: editingIndex)) return;
    setState(() {
      final item = {'start': cs, 'end': ce};
      if (editingIndex == null) {
        cloudPeriods.add(item);
      } else {
        cloudPeriods[editingIndex] = item;
      }
      cloudPeriods.sort((a, b) => a['start']!.compareTo(b['start']!));
    });
  }

  String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Future<void> pickDate(bool isStart) async {
    final d = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: isStart ? start : end,
      locale: const Locale('ar'),
    );
    if (d == null) return;
    final tStart = TimeOfDay.fromDateTime(start);
    final tEnd = TimeOfDay.fromDateTime(end);
    final startDt = DateTime(d.year, d.month, d.day, tStart.hour, tStart.minute);
    // التاريخ الظاهر واحد للسقاية، لكن وقت النهاية قد يقع في اليوم التالي.
    // نثبت ذلك في DateTime بدل محاولة استنتاجه لاحقاً من النص المعروض.
    final crosses = (tEnd.hour * 60 + tEnd.minute) <= (tStart.hour * 60 + tStart.minute);
    final endDt = DateTime(d.year, d.month, d.day + (crosses ? 1 : 0), tEnd.hour, tEnd.minute);
    setState(() {
      start = startDt;
      end = endDt;
      cloudPeriods.clear();
    });
  }

  Future<void> pickTime(bool isStart) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(isStart ? start : end),
      helpText: 'اختيار الوقت',
    );
    if (t == null) return;
    setState(() {
      if (isStart) {
        final nextStart = DateTime(start.year, start.month, start.day, t.hour, t.minute);
        final endMinutes = end.hour * 60 + end.minute;
        final startMinutes = t.hour * 60 + t.minute;
        // إذا أصبح وقت النهاية مساوياً أو أسبق من البداية، فهو تلقائياً في اليوم التالي.
        final nextEnd = DateTime(start.year, start.month, start.day + (endMinutes <= startMinutes ? 1 : 0), end.hour, end.minute);
        start = nextStart;
        end = nextEnd;
      } else {
        final startMinutes = start.hour * 60 + start.minute;
        final endMinutes = t.hour * 60 + t.minute;
        end = DateTime(start.year, start.month, start.day + (endMinutes <= startMinutes ? 1 : 0), t.hour, t.minute);
      }
      cloudPeriods.removeWhere((p) => p['start']!.isBefore(start) || p['end']!.isAfter(end));
    });
  }

  Future<void> save() async {
    if ((partyType == 'beneficiary' && bid == null) || (partyType == 'worker' && workerId == null) || (partyType == 'partner' && partnerId == null) || pumpId == null) {
      msg('يجب اختيار صاحب الحساب والمضخة');
      return;
    }
    if (minutes <= 0) {
      msg('وقت النهاية يجب أن يكون بعد وقت البداية');
      return;
    }
    if (useSession && sessionId == null) {
      msg('اختر جلسة سقي عند تفعيل استخدام وقت الجلسة');
      return;
    }
    if (managerOverride && !widget.manager) {
      msg('تجاوز مدة الانتظار متاح للمدير فقط');
      return;
    }
    if (managerOverride && reason.text.trim().isEmpty) {
      msg('أدخل سبب تجاوز مدة الانتظار');
      return;
    }
    setState(() => loading = true);
    try {
      await widget.r.accounting.recordIrrigation(
        stationId: 1,
        pumpId: pumpId!,
        beneficiaryId: partyType == 'beneficiary' ? bid : null,
        workerId: partyType == 'worker' ? workerId : null,
        partnerId: partyType == 'partner' ? partnerId : null,
        partyType: partyType,
        start: start,
        end: end,
        systemType: type,
        waterRate: waterRate,
        litersPerHour: liters,
        dieselPrice: dieselPrice,
        solarRate: solarRate,
        thirdRate: thirdRate,
        cloudMinutes: cloudMin,
        cloudPeriods: cloudPeriods.map((p) => {'start': p['start']!.toIso8601String(), 'end': p['end']!.toIso8601String()}).toList(),
        paidAmount: int.tryParse(paid.text) ?? 0,
        paymentMethodId: payMethod,
        bookingId: bookingId,
        queueId: queueId,
        sessionId: sessionId,
        overrideWaitingPeriod: managerOverride,
        overrideReason: reason.text,
      );
      if (mounted) setState(() => saved = true);
      msg('تم حفظ السقاية والقيد المحاسبي بنجاح');
    } catch (e) {
      msg(friendlyError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void newOperation() {
    setState(() {
      saved = false;
      start = DateTime.now();
      end = DateTime.now().add(const Duration(hours: 1));
      paid.text = '0';
      cloudPeriods.clear();
      reason.clear();
      managerOverride = false;
      queueId = null;
      bookingId = null;
      sessionId = null;
    });
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(c) {
    if (loading && beneficiaries.isEmpty) return const LoadingView();
    final p = preview();
    final filtered = beneficiaries
        .where(
          (x) =>
              '${x['name']} ${x['phone'] ?? ''} ${x['jerba_number'] ?? ''} ${x['location'] ?? ''}'
                  .contains(search),
        )
        .toList();
    final selectedHistory = history;
    return PageFrame(
      title: 'سقاية جديدة',
      subtitle:
          'عملية سقي كاملة مرتبطة بالدور الحالي والحساب والقيد المحاسبي',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث'),
        ),
        if (saved)
          OutlinedButton.icon(
            onPressed: newOperation,
            icon: const Icon(Icons.add),
            label: const Text('عملية جديدة'),
          ),
        FilledButton.icon(
          onPressed: loading || saved ? null : save,
          icon: const Icon(Icons.save),
          label: const Text('حفظ السقاية'),
        ),
      ],
      child: ListView(
        children: [
          SectionCard(
            title: '1. البحث واختيار المستفيد',
            icon: Icons.person_search,
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: partyType,
                  items: const [
                    DropdownMenuItem(value: 'beneficiary', child: Text('مستفيد')),
                    DropdownMenuItem(value: 'worker', child: Text('عامل')),
                    DropdownMenuItem(value: 'partner', child: Text('شريك')),
                  ],
                  onChanged: (v) => setState(() { partyType = v!; bid = null; workerId = null; partnerId = null; }),
                  decoration: const InputDecoration(labelText: 'صاحب حساب السقاية'),
                ),
                TextField(
                  onChanged: (v) => setState(() => search = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText:
                        'بحث سريع بالاسم أو الهاتف أو رقم الجربة أو الموقع',
                  ),
                ),
                const SizedBox(height: 10),
                if (partyType == 'beneficiary')
                  fieldSelect<int>(
                    'المستفيد',
                    bid,
                    filtered.map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']} • ${x['jerba_number'] ?? 'بدون رقم جربة'}'))).toList(),
                    (v) { if (v != null) selectBeneficiary(v); },
                  ),
                if (partyType == 'worker')
                  fieldSelect<int>('العامل', workerId, workers.where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(search)).map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}'))).toList(), (v) => setState(() => workerId = v)),
                if (partyType == 'partner')
                  fieldSelect<int>('الشريك', partnerId, partners.where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(search)).map((x) => DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}'))).toList(), (v) => setState(() => partnerId = v)),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    Metric(
                      'أول سقاية',
                      selectedHistory.isEmpty
                          ? 'لا توجد'
                          : '${selectedHistory.last['date'] ?? '-'}',
                      _blue,
                    ),
                    Metric(
                      'عدد السقايات',
                      '${selectedHistory.length}',
                      _purple,
                    ),
                    if (partyType == 'beneficiary' && type == 'diesel')
                      Metric(
                        'رصيد ديزل المستفيد',
                        '${beneficiaryDiesel.toStringAsFixed(2)} لتر',
                        _cyan,
                      ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: '2. بيانات التشغيل',
            icon: Icons.settings_input_component,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                DateButton('التاريخ', start, () => pickDate(true)),
                DateButton('وقت البداية', start, () => pickTime(true)),
                DateButton('وقت النهاية', end, () => pickTime(false)),
                if (end.year != start.year || end.month != start.month || end.day != start.day)
                  const Chip(avatar: Icon(Icons.nights_stay_outlined), label: Text('وقت النهاية في اليوم التالي')),
                Chip(
                  label: Text('المدة: $minutes دقيقة'),
                  avatar: const Icon(Icons.timelapse),
                ),
                if (type == 'solar') ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: minutes > 0 ? () => addCloudPeriod() : null,
                    icon: const Icon(Icons.cloud_outlined),
                    label: const Text('إضافة فترة غيم'),
                  ),
                  if (cloudPeriods.isNotEmpty)
                    ...cloudPeriods.asMap().entries.map((entry) {
                      final i = entry.key;
                      final p = entry.value;
                      final m = p['end']!.difference(p['start']!).inMinutes;
                      return InputChip(
                        avatar: const Icon(Icons.cloud, size: 18),
                        label: Text('غيم ${i + 1}: ${_hm(p['start']!)} → ${_hm(p['end']!)} • $m دقيقة'),
                        onPressed: () => addCloudPeriod(editingIndex: i),
                        onDeleted: () => setState(() => cloudPeriods.removeAt(i)),
                      );
                    }),
                  if (cloudPeriods.isNotEmpty)
                    Chip(
                      avatar: const Icon(Icons.remove_circle_outline),
                      label: Text('خصم الغيم: $cloudMin دقيقة • المحاسبة: ${minutes - cloudMin} دقيقة'),
                    ),
                ],
              ],
            ),
          ),
          SectionCard(
            title: '3. الدور وطريقة الوقت',
            icon: Icons.alt_route_rounded,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                Container(
                  constraints: const BoxConstraints(minWidth: 280, maxWidth: 520),
                  child: fieldSelect<int>(
                    queueType == 'booking' ? 'الدور المحجوز' : 'الدور الحالي',
                    queueType == 'booking' ? bookingId : queueId,
                    [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('بدون ربط بالدور'),
                      ),
                      if (queueType == 'booking')
                        for (final x in bookings.where(
                          (x) =>
                              (bid == null || x['beneficiary_id'] == bid) &&
                              ['scheduled', 'accepted', 'notified'].contains('${x['status']}'),
                        ))
                          DropdownMenuItem(
                            value: x['id'] as int,
                            child: Text(
                              'الدور • ${x['beneficiary_name']} • ${x['scheduled_start'] ?? 'الموعد غير محدد'}',
                            ),
                          )
                      else
                        for (final x in queue.where(
                          (x) => bid == null || x['beneficiary_id'] == bid,
                        ))
                          DropdownMenuItem(
                            value: x['id'] as int,
                            child: Text(
                              'الدور ${x['position']} • ${x['beneficiary_name']}',
                            ),
                          ),
                    ],
                    (v) => setState(() {
                      queueId = queueType == 'circular' ? v : null;
                      bookingId = queueType == 'booking' ? v : null;
                    }),
                  ),
                ),
                fieldSelect<int>('جلسة سقي محفوظة', sessionId, [
                  const DropdownMenuItem(value: null, child: Text('بدون جلسة')),
                  for (final x in sessions.where(
                    (x) => bid == null || x['beneficiary_id'] == bid,
                  ))
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text(
                        '${statusName(x['status'])} • ${x['actual_start'] ?? x['planned_start'] ?? ''}',
                      ),
                    ),
                ], (v) => setState(() => sessionId = v)),
                SizedBox(
                  width: 220,
                  child: SwitchListTile(
                    value: useSession,
                    onChanged: (v) => setState(() => useSession = v),
                    title: const Text('استخدام وقت جلسة السقي'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          SectionCard(
            title: '4. السعر والخصومات والدفع',
            icon: Icons.calculate,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (type == 'diesel') ...[
                  Metric('سعر المياه', money(waterRate), _blue),
                  Metric('سعر الديزل', money(dieselPrice), _purple),
                ],
                if (type == 'solar') ...[
                  Metric('السعر الشمسي', money(solarRate), _cyan),
                ],
                if (type == 'equivalent_hybrid') ...[
                  Metric('سعر النوع الثالث', money(thirdRate), _cyan),
                ],
                SizedBox(
                  width: 230,
                  child: TextField(
                    controller: paid,
                    onChanged: (_) => setState(() {}),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'المدفوع الآن',
                      hintText: 'بالريال',
                    ),
                  ),
                ),
                if ((int.tryParse(paid.text) ?? 0) > 0 && methods.isNotEmpty)
                  SizedBox(
                    width: 230,
                    child: DropdownButtonFormField<int>(
                      value: payMethod,
                      items: [
                        for (final x in methods)
                          DropdownMenuItem(value: x['id'] as int, child: Text('${x['name']}')),
                      ],
                      onChanged: (v) => setState(() => payMethod = v),
                      decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                    ),
                  ),
                if (widget.manager)
                  SizedBox(
                    width: 240,
                    child: Column(
                      children: [
                        CheckboxListTile(
                          value: managerOverride,
                          onChanged: (v) =>
                              setState(() => managerOverride = v ?? false),
                          title: const Text('تجاوز مدة الانتظار'),
                          contentPadding: EdgeInsets.zero,
                        ),
                        if (managerOverride)
                          TextField(
                            controller: reason,
                            decoration: const InputDecoration(
                              labelText: 'سبب التجاوز *',
                              hintText: 'السبب مطلوب للتدقيق',
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: '5. المعاينة قبل الحفظ',
            icon: Icons.receipt_long,
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                Metric(
                  'القابل للمحاسبة',
                  '${p['القابل للمحاسبة']} دقيقة',
                  _cyan,
                ),
                Metric('قيمة المياه', money(p['المياه']), _blue),
                Metric('قيمة الديزل', money(p['الديزل']), _purple),
                Metric('الإجمالي المستحق', money(p['الإجمالي']), _green),
                Metric('المدفوع', money(p['المدفوع']), _blue),
                Metric(
                  'حالة الرصيد',
                  AccountingCalculations.balanceLabel(
                    p['حالة الرصيد']!.round(),
                  ),
                  p['حالة الرصيد']! > 0 ? Colors.orange : _green,
                ),
              ],
            ),
          ),
          if (saved)
            Card(
              color: _green.withOpacity(.08),
              child: const ListTile(
                leading: Icon(Icons.check_circle, color: _green),
                title: Text('تم الحفظ بنجاح'),
                subtitle: Text(
                  'تم إنشاء السقاية والقيد المحاسبي وتحديث الرصيد. يمكنك بدء عملية جديدة.',
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_outline, color: _green),
              title: const Text('تثبيت الأسعار'),
              subtitle: const Text(
                'تُحفظ أسعار العملية كنسخة تاريخية مستقلة، فلا تتغير حسابات السقاية عند تعديل الأسعار لاحقًا.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget fieldSelect<T>(
    String label,
    T? value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> f,
  ) => SizedBox(
    width: 270,
    child: DropdownButtonFormField<T>(
      value: value,
      items: items,
      onChanged: f,
      decoration: InputDecoration(labelText: label, hintText: 'اختر $label'),
    ),
  );
}

class DateButton extends StatelessWidget {
  final String label;
  final DateTime value;
  final VoidCallback onTap;
  const DateButton(this.label, this.value, this.onTap, {super.key});
  @override
  Widget build(BuildContext c) => OutlinedButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.event),
    label: Text(
      '$label: ${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}',
    ),
  );
}

class Metric extends StatelessWidget {
  final String a, b;
  final Color color;
  const Metric(this.a, this.b, this.color, {super.key});
  @override
  Widget build(BuildContext c) => Container(
    width: 190,
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(18),
      color: color.withOpacity(.08),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(a),
        Text(
          b,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    ),
  );
}

class SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    super.key,
  });
  @override
  Widget build(BuildContext c) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(c).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

class FormDialog extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final VoidCallback onSave;
  const FormDialog({
    required this.title,
    required this.children,
    required this.onSave,
    super.key,
  });
  @override
  Widget build(BuildContext c) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(child: Column(children: children)),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('إلغاء')),
      FilledButton(onPressed: onSave, child: const Text('حفظ')),
    ],
  );
}

class IrrigationsPage extends StatefulWidget {
  final StationRepository r;
  final bool manager;
  const IrrigationsPage(this.r, {required this.manager, super.key});
  @override
  State<IrrigationsPage> createState() => _IrrigationsState();
}

class _IrrigationsState extends State<IrrigationsPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [];
  String q = '';
  String? type;
  int? bid;
  bool loading = true;

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final x = await widget.r.irrigations(
        systemType: type,
        beneficiaryId: bid,
      );
      if (mounted)
        setState(() {
          rows = x;
          loading = false;
        });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.r.beneficiaries().then((x) {
      if (mounted) setState(() => bs = x);
    });
    load();
  }

  String _timeOf(Object? value) {
    final d = DateTime.tryParse('$value');
    return d == null ? '-' : DateFormat('HH:mm').format(d);
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['beneficiary_name']}'.contains(q))
        .toList();
    return PageFrame(
      title: 'السقايات',
      subtitle: 'سجل السقايات مع البحث والتصفية ومراجعة الحالة',
      actions: [
        FilledButton.icon(
          onPressed: () => Navigator.push(
            c,
            MaterialPageRoute(
              builder: (_) =>
                  NewIrrigationPage(widget.r, manager: widget.manager),
            ),
          ).then((_) => load()),
          icon: const Icon(Icons.add),
          label: const Text('سقاية جديدة'),
        ),
      ],
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  onChanged: (v) => setState(() => q = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'بحث باسم المستفيد',
                  ),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String>(
                  value: type,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('كل المنظومات')),
                    DropdownMenuItem(value: 'diesel', child: Text('ديزل')),
                    DropdownMenuItem(value: 'solar', child: Text('شمسي')),
                    DropdownMenuItem(
                      value: 'equivalent_hybrid',
                      child: Text('النوع الثالث'),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => type = v);
                    load();
                  },
                  decoration: const InputDecoration(labelText: 'المنظومة'),
                ),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int>(
                  value: bid,
                  items: [
                    const DropdownMenuItem<int>(
                      value: null,
                      child: Text('كل المستفيدين'),
                    ),
                    for (final b in bs)
                      DropdownMenuItem(
                        value: b['id'] as int,
                        child: Text('${b['name']}'),
                      ),
                  ],
                  onChanged: (v) {
                    setState(() => bid = v);
                    load();
                  },
                  decoration: const InputDecoration(labelText: 'المستفيد'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (loading) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty && !loading
                ? const EmptyView('لا توجد سقايات مطابقة')
                : Card(
                    margin: EdgeInsets.zero,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: DataTable(
                          headingRowHeight: 52,
                          dataRowMinHeight: 62,
                          columns: const [
                            DataColumn(label: Text('الجهة')),
                            DataColumn(label: Text('من')),
                            DataColumn(label: Text('إلى')),
                            DataColumn(label: Text('المدة')),
                            DataColumn(label: Text('المدفوع')),
                            DataColumn(label: Text('المبلغ')),
                            DataColumn(label: Text('الغيم')),
                            DataColumn(label: Text('حالة الخصم')),
                          ],
                          rows: [
                            for (final x in filtered)
                              DataRow(cells: [
                                DataCell(Text('${x['beneficiary_name'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.w800))),
                                DataCell(Text(_timeOf(x['start_datetime']))),
                                DataCell(Text(_timeOf(x['end_datetime']))),
                                DataCell(Text('${x['minutes'] ?? 0} دقيقة')),
                                DataCell(Text(money(x['paid_amount']))),
                                DataCell(Text(money(x['total_amount']))),
                                DataCell(Text('${x['cloud_minutes'] ?? 0} دقيقة')),
                                DataCell(
                                  Chip(
                                    avatar: Icon(
                                      ((x['cloud_minutes'] as num?)?.round() ?? 0) > 0 ? Icons.cloud : Icons.cloud_off,
                                      size: 16,
                                    ),
                                    label: Text(
                                      ((x['cloud_minutes'] as num?)?.round() ?? 0) > 0 ? 'تم الخصم' : 'لا يوجد خصم',
                                    ),
                                  ),
                                ),
                              ]),
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

class SessionsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const SessionsPage(this.r, {required this.userId, super.key});
  @override
  State<SessionsPage> createState() => _SessionsState();
}

class _SessionsState extends State<SessionsPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [], qs = [], ps = [], bookings = [];
  String q = '';
  String queueType = 'circular';
  Timer? ticker;
  DateTime now = DateTime.now();

  Future<void> load() async {
    try {
      final a = await widget.r.sessions();
      final b = await widget.r.beneficiaries();
      final st = await widget.r.settings();
      final queueTypeValue = st['queue_type'] ?? 'circular';
      final queue = queueTypeValue == 'booking' ? <Map<String, Object?>>[] : await widget.r.queue();
      final bookingsValue = queueTypeValue == 'booking' ? await widget.r.bookings('scheduled') : <Map<String, Object?>>[];
      final selectedId = int.tryParse(st['selected_pump_id'] ?? '');
      final pumps = selectedId == null
          ? <Map<String, Object?>>[]
          : await widget.r.db.query('pumps', where: 'id=? AND active=1', whereArgs: [selectedId]);
      if (mounted)
        setState(() {
          rows = a;
          bs = b;
          qs = queue;
          bookings = bookingsValue;
          queueType = queueTypeValue;
          ps = pumps;
        });
    } catch (e) {
      msg(friendlyError(e));
    }
  }

  @override
  void initState() {
    super.initState();
    load();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => now = DateTime.now());
    });
  }

  @override
  void dispose() {
    ticker?.cancel();
    super.dispose();
  }

  Future<void> start() async {
    int? b = bs.isEmpty ? null : bs.first['id'] as int;
    int? p = ps.isEmpty ? null : ps.first['id'] as int;
    int? queueId;
    int? bookId;
    final bookings = await widget.r.bookings('scheduled');

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('بدء جلسة سقي'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  value: b,
                  items: [
                    for (final x in bs)
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => b = v),
                  decoration: const InputDecoration(labelText: 'المستفيد'),
                ),
                DropdownButtonFormField<int>(
                  value: queueType == 'booking' ? bookId : queueId,
                  items: [
                    const DropdownMenuItem<int>(
                      value: null,
                      child: Text('بدون ربط بالدور'),
                    ),
                    if (queueType == 'booking')
                      for (final x in bookings.where(
                        (x) => b == null || x['beneficiary_id'] == b,
                      ))
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text(
                            'الدور • ${x['beneficiary_name']} • ${x['scheduled_start'] ?? 'الموعد غير محدد'}',
                          ),
                        )
                    else
                      for (final x in qs.where(
                        (x) => b == null || x['beneficiary_id'] == b,
                      ))
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text(
                            'الدور ${x['position']} • ${x['beneficiary_name']}',
                          ),
                        ),
                  ],
                  onChanged: (v) => s(() {
                    queueId = queueType == 'circular' ? v : null;
                    bookId = queueType == 'booking' ? v : null;
                  }),
                  decoration: InputDecoration(
                    labelText: queueType == 'booking' ? 'الدور المحجوز' : 'الدور الحالي',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, b != null && p != null),
              child: const Text('بدء'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      try {
        await widget.r.startSession(
          beneficiaryId: b!,
          pumpId: p!,
          queueId: queueId,
          bookingId: bookId,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> stop(int id) async {
    try {
      await widget.r.stopSession(id, userId: widget.userId);
      await load();
      msg('تم إنهاء الجلسة وإنشاء السقاية المحاسبية');
    } catch (e) {
      msg(friendlyError(e));
    }
  }

  Future<void> postpone(int id) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تأجيل جلسة',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(
              labelText: 'سبب التأجيل *',
              hintText: 'سيظهر في سجل التدقيق',
            ),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.postponeSession(id, c.text, userId: widget.userId))) return;
      await load();
    }
  }

  String elapsed(Object? start) {
    if (start == null) return '00:00:00';
    final d = now.difference(DateTime.tryParse('$start') ?? now);
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$sec';
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['beneficiary_name']} ${x['pump_name']}'.contains(q))
        .toList();
    return PageFrame(
      title: 'جلسات السقي',
      subtitle: 'مؤقت حقيقي محفوظ في قاعدة البيانات مع بدء وإيقاف وتأجيل',
      actions: [
        FilledButton.icon(
          onPressed: start,
          icon: const Icon(Icons.play_arrow),
          label: const Text('بدء جلسة'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم المستفيد أو المضخة',
              hintText: 'ابحث داخل الجلسات',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا توجد جلسات مطابقة')
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 7),
                    itemBuilder: (_, i) {
                      final x = filtered[i];
                      final running = x['status'] == 'running';
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            running ? Icons.timer : Icons.check_circle,
                            color: running ? _green : _blue,
                          ),
                          title: Text(
                            '${x['beneficiary_name']} • ${x['pump_name']}',
                          ),
                          subtitle: Text(
                            '${statusName(x['status'])} • البداية: ${x['actual_start'] ?? x['planned_start'] ?? '-'}',
                          ),
                          trailing: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (running)
                                Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Text(
                                    elapsed(x['actual_start']),
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                      color: _cyan,
                                    ),
                                  ),
                                ),
                              if (running)
                                IconButton(
                                  tooltip: 'إنهاء الجلسة',
                                  onPressed: () => stop(x['id'] as int),
                                  icon: const Icon(
                                    Icons.stop_circle,
                                    color: Colors.red,
                                  ),
                                ),
                              if (running)
                                IconButton(
                                  tooltip: 'تأجيل',
                                  onPressed: () => postpone(x['id'] as int),
                                  icon: const Icon(Icons.pause_circle),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class QueueBookingPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final bool manager;
  const QueueBookingPage(
    this.r, {
    required this.userId,
    required this.manager,
    super.key,
  });
  @override
  State<QueueBookingPage> createState() => _QueueState();
}

class _QueueState extends State<QueueBookingPage> {
  List<Map<String, Object?>> q = [], b = [], bs = [];
  String? status;
  String queueType = 'circular';

  bool get isBookingMode => queueType == 'booking';

  Future<void> load() async {
    final settings = await widget.r.settings();
    final mode = settings['queue_type'] ?? 'circular';
    final allBeneficiaries = await widget.r.beneficiaries();
    final queue = mode == 'booking' ? <Map<String, Object?>>[] : await widget.r.queue();
    final bookings = mode == 'booking'
        ? await widget.r.bookings(status)
        : <Map<String, Object?>>[];
    if (mounted) {
      setState(() {
        queueType = mode;
        q = queue;
        b = bookings;
        bs = allBeneficiaries;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> addQueue() async {
    int? id = bs.isEmpty ? null : bs.first['id'] as int;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة إلى الدور'),
          content: DropdownButtonFormField<int>(
            value: id,
            items: [
              for (final x in bs)
                DropdownMenuItem(
                  value: x['id'] as int,
                  child: Text('${x['name']}'),
                ),
            ],
            onChanged: (v) => s(() => id = v),
            decoration: const InputDecoration(labelText: 'المستفيد'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, id != null),
              child: const Text('إضافة'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && id != null) {
      await widget.r.enqueue(id!, userId: widget.userId);
      await load();
    }
  }

  Future<void> book() async {
    int? id = bs.isEmpty ? null : bs.first['id'] as int;
    final n = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة طلب إلى الدور'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: id,
                items: [
                  for (final x in bs)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => id = v),
                decoration: const InputDecoration(labelText: 'المستفيد'),
              ),
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, id != null),
              child: const Text('إرسال الطلب'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && id != null) {
      if (!await runGuarded(context, () => widget.r.createBooking(id!, n.text, userId: widget.userId))) return;
      await load();
    }
  }

  Future<void> review(Map<String, Object?> x) async {
    String st = 'scheduled';
    final reason = TextEditingController();
    DateTime? start;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('إدارة دور ${x['beneficiary_name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: st,
                items: const [
                  DropdownMenuItem(value: 'scheduled', child: Text('محدد الموعد')),
                  DropdownMenuItem(value: 'accepted', child: Text('مقبول')),
                  DropdownMenuItem(value: 'cancelled', child: Text('ملغى')),
                ],
                onChanged: (v) => s(() => st = v!),
                decoration: const InputDecoration(labelText: 'الحالة'),
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(
                  labelText: 'السبب أو الملاحظة',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (st == 'scheduled' || st == 'accepted') {
      final d = await showDatePicker(
        context: context,
        firstDate: DateTime.now(),
        lastDate: DateTime(2100),
        initialDate: DateTime.now(),
        locale: const Locale('ar'),
      );
      if (d != null) {
        final t = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
          helpText: 'اختيار وقت الموعد',
        );
        if (t != null) {
          start = DateTime(d.year, d.month, d.day, t.hour, t.minute);
        }
      }
    }
    await widget.r.reviewBooking(
      x['id'] as int,
      status: st,
      reviewer: widget.userId,
      reason: reason.text,
      start: start,
      end: start?.add(const Duration(hours: 1)),
    );
    await load();
  }

  Future<void> postpone(int id) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تأجيل الدور',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'سبب التأجيل *'),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.postponeQueue(id, c.text, userId: widget.userId))) return;
      await load();
    }
  }

  Future<void> completeEntry(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('تمت الخدمة'),
        content: const Text('تسجيل أن هذا المستفيد خُدم دون سقاية في النظام؟ في الطابور الدائري يعود إلى آخر الدور.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('تأكيد')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!await runGuarded(context, () => widget.r.completeQueue(id, userId: widget.userId))) return;
    await load();
  }

  Future<void> overrideQ(int id) async {
    if (!widget.manager) return;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'تجاوز الدور',
        children: [
          TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'سبب التجاوز *'),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.serveSpecific(id, widget.userId, c.text))) return;
      await load();
    }
  }

  @override
  Widget build(BuildContext c) {
    final modeTitle = isBookingMode ? 'حجز' : 'دور دائري';
    final entries = isBookingMode ? b : q;
    return PageFrame(
      title: 'إدارة الدور',
      subtitle: 'مسار واحد للدور، يتغير أسلوبه حسب إعداد المحطة: $modeTitle',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('تحديث'),
        ),
        if (isBookingMode)
          FilledButton.icon(
            onPressed: book,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة طلب للدور'),
          )
        else
          FilledButton.icon(
            onPressed: addQueue,
            icon: const Icon(Icons.add_rounded),
            label: const Text('إضافة إلى الدور'),
          ),
      ],
      child: ListView(
        children: [
          if (isBookingMode) ...[
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _statusChip('كل الطلبات', null),
                _statusChip('جديد', 'new'),
                _statusChip('قيد المراجعة', 'under_review'),
                _statusChip('محدد الموعد', 'scheduled'),
                _statusChip('مكتمل', 'completed'),
              ],
            ),
            const SizedBox(height: 14),
          ],
          SectionCard(
            title: isBookingMode ? 'الدور الحالي' : 'ترتيب الدور الحالي',
            icon: Icons.format_list_numbered_rounded,
            child: entries.isEmpty
                ? EmptyView(isBookingMode ? 'لا توجد طلبات في الدور' : 'الدور فارغ')
                : Column(
                    children: [
                      for (var i = 0; i < entries.length; i++)
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            leading: CircleAvatar(
                              child: Text(isBookingMode ? '${i + 1}' : '${entries[i]['position']}'),
                            ),
                            title: Text('${entries[i]['beneficiary_name']}'),
                            subtitle: Text(
                              isBookingMode
                                  ? '${statusName(entries[i]['status'])} • ${entries[i]['created_at']} • ${entries[i]['scheduled_start'] ?? 'الموعد غير محدد'}'
                                  : '${statusName(entries[i]['status'])} • مرات التأجيل: ${entries[i]['postponed_count'] ?? 0}',
                            ),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  tooltip: 'التفاصيل',
                                  onPressed: () => Navigator.push(
                                    c,
                                    MaterialPageRoute(
                                      builder: (_) => RecordDetailsPage(
                                        widget.r,
                                        kind: isBookingMode ? 'booking' : 'queue',
                                        id: entries[i]['id'] as int,
                                        title: isBookingMode ? 'تفاصيل الدور' : 'تفاصيل الدور',
                                      ),
                                    ),
                                  ),
                                  icon: const Icon(Icons.info_outline_rounded),
                                ),
                                if (isBookingMode)
                                  IconButton(
                                    tooltip: 'إدارة الدور',
                                    onPressed: () => review(entries[i]),
                                    icon: const Icon(Icons.edit_calendar_rounded),
                                  )
                                else ...[
                                  IconButton(
                                    tooltip: 'تأجيل',
                                    onPressed: () => postpone(entries[i]['id'] as int),
                                    icon: const Icon(Icons.pause_rounded),
                                  ),
                                  IconButton(
                                    tooltip: 'تمت الخدمة',
                                    onPressed: () => completeEntry(entries[i]['id'] as int),
                                    icon: const Icon(Icons.check_circle_outline_rounded),
                                  ),
                                  if (widget.manager)
                                    IconButton(
                                      tooltip: 'تجاوز',
                                      onPressed: () => overrideQ(entries[i]['id'] as int),
                                      icon: const Icon(Icons.flash_on_rounded),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          if (isBookingMode)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'طلبات الحجز هنا هي مرحلة طلب الدور نفسها، وعند قبولها/تحديد موعدها تبقى في نفس المسار دون إنشاء قائمة طابور ثانية للمستخدم.',
                style: Theme.of(c).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusChip(String label, String? value) => ChoiceChip(
        label: Text(label),
        selected: status == value,
        onSelected: (_) {
          setState(() => status = value);
          load();
        },
      );
}

class DieselPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const DieselPage(this.r, {required this.userId, super.key});
  @override
  State<DieselPage> createState() => _DieselState();
}

class _DieselState extends State<DieselPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> bs = [], cs = [];
  double stock = 0;
  Map<String, Object?>? warning;
  String q = '';
  Future<void> load() async {
    final cfg = await SystemConfig.load(widget.r);
    if (!cfg.isDiesel) {
      if (mounted) setState(() => enabled = false);
      return;
    }
    final a = await widget.r.diesel(),
        b = await widget.r.beneficiaries(),
        c = await widget.r.cashboxes(),
        s = await widget.r.dieselStock(),
        w = await widget.r.dieselWarning();
    if (mounted)
      setState(() {
        rows = a;
        bs = b;
        cs = c;
        stock = s;
        warning = w;
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    String kind = 'receipt';
    int? bid, cb = cs.isEmpty ? null : cs.first['id'] as int;
    final liters = TextEditingController(),
        price = TextEditingController(text: '0'),
        notes = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('حركة ديزل'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: kind,
                  items: const [
                    DropdownMenuItem(
                      value: 'receipt',
                      child: Text('شراء وإضافة للمخزون'),
                    ),
                    DropdownMenuItem(
                      value: 'delivery',
                      child: Text('تسليم لمستفيد'),
                    ),
                    DropdownMenuItem(
                      value: 'advance',
                      child: Text('سلفة ديزل'),
                    ),
                    DropdownMenuItem(
                      value: 'correction',
                      child: Text('تصحيح مخزون'),
                    ),
                  ],
                  onChanged: (v) => s(() => kind = v!),
                  decoration: const InputDecoration(labelText: 'نوع الحركة'),
                ),
                if (kind == 'delivery' || kind == 'advance')
                  DropdownButtonFormField<int>(
                    value: bid,
                    items: [
                      for (final x in bs)
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text('${x['name']}'),
                        ),
                    ],
                    onChanged: (v) => s(() => bid = v),
                    decoration: const InputDecoration(labelText: 'المستفيد'),
                  ),
                if (kind == 'receipt')
                  DropdownButtonFormField<int>(
                    value: cb,
                    items: [
                      for (final x in cs)
                        DropdownMenuItem(
                          value: x['id'] as int,
                          child: Text('${x['name']}'),
                        ),
                    ],
                    onChanged: (v) => s(() => cb = v),
                    decoration: const InputDecoration(labelText: 'الصندوق'),
                  ),
                TextField(
                  controller: liters,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الكمية باللتر'),
                ),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'سعر اللتر'),
                ),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(labelText: 'ملاحظات'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.addDieselMovement(
          beneficiaryId: bid,
          kind: kind,
          liters: double.tryParse(liters.text) ?? 0,
          unitPrice: int.tryParse(price.text) ?? 0,
          date: DateTime.now(),
          cashboxId: cb,
          userId: widget.userId,
          notes: notes.text,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  bool enabled = true;

  @override
  Widget build(c) => enabled
      ? PageFrame(
    title: 'الديزل',
    subtitle: 'المخزون والحركات والتنبيه والسلف والتسليم',
    actions: [
      if (warning?['warning'] == true)
        OutlinedButton.icon(
          onPressed: () async {
            final m =
                double.tryParse(
                  (await widget.r.settings())['diesel_snooze_minutes'] ?? '10',
                ) ??
                10;
            if (!await runGuarded(context, () => widget.r.setSetting(
              'diesel_warning_snoozed_until',
              DateTime.now()
                  .add(Duration(minutes: m.round()))
                  .toIso8601String(),
            ))) return;
            await load();
          },
          icon: const Icon(Icons.snooze),
          label: const Text('تأجيل التنبيه 10 دقائق'),
        ),
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.local_gas_station),
        label: const Text('حركة ديزل'),
      ),
    ],
    child: Column(
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.oil_barrel, color: _cyan),
            title: const Text('المخزون الحالي'),
            subtitle: Text('${stock.toStringAsFixed(2)} لتر'),
            trailing: warning?['warning'] == true
                ? const Icon(Icons.warning_amber, color: Colors.orange)
                : const Icon(Icons.check_circle, color: _green),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث في حركات الديزل',
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            children: [
              for (final x in rows.where(
                (x) =>
                    '${x['beneficiary_name'] ?? ''} ${x['kind']} ${x['notes'] ?? ''}'
                        .contains(q),
              ))
                Card(
                  child: ListTile(
                    title: Text(
                      '${x['beneficiary_name'] ?? 'المخزون'} • ${statusName(x['kind'])}',
                    ),
                    subtitle: Text('${x['liters']} لتر • ${x['date']}'),
                    trailing: Text(money(x['amount'])),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  )
      : const Center(child: Text('عناصر الديزل غير متاحة لأن المنظومة شمسية.'));
}

class PaymentsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const PaymentsPage(this.r, {required this.userId, super.key});
  @override
  State<PaymentsPage> createState() => _PaymentsState();
}

class _PaymentsState extends State<PaymentsPage> {
  List<Map<String, Object?>> rows = [],
      bs = [],
      ws = [],
      ps = [],
      methods = [],
      cash = [];
  String target = 'beneficiary', q = '';
  Future<void> load() async {
    final a = await widget.r.payments(),
        b = await widget.r.beneficiaries(),
        w = await widget.r.workers(),
        p = await widget.r.partners(),
        m = await widget.r.paymentMethods(),
        c = await widget.r.cashboxes();
    if (mounted)
      setState(() {
        rows = a;
        bs = b;
        ws = w;
        ps = p;
        methods = m;
        cash = c;
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final list = target == 'beneficiary'
        ? bs
        : target == 'worker'
        ? ws
        : ps;
    int? party = list.isEmpty ? null : list.first['id'] as int;
    int? method = methods.isEmpty ? null : methods.first['id'] as int;
    int? cb = cash.isEmpty ? null : cash.first['id'] as int;
    final amount = TextEditingController(),
        note = TextEditingController(),
        reference = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تسجيل دفعة'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: target,
                  items: const [
                    DropdownMenuItem(
                      value: 'beneficiary',
                      child: Text('مستفيد'),
                    ),
                    DropdownMenuItem(value: 'worker', child: Text('عامل')),
                    DropdownMenuItem(value: 'partner', child: Text('شريك')),
                  ],
                  onChanged: (v) {
                    if (v != null)
                      s(() {
                        target = v;
                        final l = target == 'beneficiary'
                            ? bs
                            : target == 'worker'
                            ? ws
                            : ps;
                        party = l.isEmpty ? null : l.first['id'] as int;
                      });
                  },
                  decoration: const InputDecoration(labelText: 'الطرف'),
                ),
                DropdownButtonFormField<int>(
                  value: party,
                  items: [
                    for (final x
                        in (target == 'beneficiary'
                            ? bs
                            : target == 'worker'
                            ? ws
                            : ps))
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => party = v),
                  decoration: InputDecoration(
                    labelText: '${targetName(target)}',
                  ),
                ),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'المبلغ'),
                ),
                DropdownButtonFormField<int>(
                  value: method,
                  items: [
                    for (final x in methods)
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => method = v),
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                ),
                DropdownButtonFormField<int>(
                  value: cb,
                  items: [
                    for (final x in cash)
                      DropdownMenuItem(
                        value: x['id'] as int,
                        child: Text('${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => s(() => cb = v),
                  decoration: const InputDecoration(labelText: 'الصندوق'),
                ),
                TextField(
                  controller: reference,
                  decoration: const InputDecoration(labelText: 'رقم مرجعي'),
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'ملاحظات'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                party != null &&
                    method != null &&
                    cb != null &&
                    int.tryParse(amount.text) != null,
              ),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        final a = int.parse(amount.text);
        if (target == 'beneficiary') {
          await widget.r.accounting.receivePayment(
            beneficiaryId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            referenceNumber: reference.text,
            notes: note.text,
          );
          final bal = await widget.r.accounting.beneficiaryBalance(party!);
          await widget.r.notify(
            beneficiaryId: party!,
            type: 'payment',
            title: 'تسجيل دفعة',
            body: 'تم تسجيل دفعة بمبلغ $a ريال',
          );
          await widget.r.notify(
            beneficiaryId: party!,
            type: 'balance',
            title: 'تحديث الرصيد',
            body:
                'الرصيد الحالي: ${AccountingCalculations.balanceLabel(bal['balance'] ?? 0)}',
          );
        } else if (target == 'worker')
          await widget.r.accounting.payWorker(
            workerId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            notes: note.text,
          );
        else
          await widget.r.accounting.payPartner(
            partnerId: party!,
            amount: a,
            paymentMethodId: method!,
            cashboxId: cb!,
            userId: widget.userId,
            notes: note.text,
          );
        await load();
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('تمت العملية'),
            content: const Text(
              'تم حفظ الدفعة وتحديث الرصيد وإنشاء إشعار داخل التطبيق عند توفر المستفيد.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إغلاق'),
              ),
            ],
          ),
        );
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المدفوعات',
    subtitle: 'قبض المستفيدين ودفع مستحقات العمال والشركاء',
    actions: [
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.add_card),
        label: const Text('تسجيل دفعة'),
      ),
    ],
    child: Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final x in const [
              ('beneficiary', 'المستفيدون'),
              ('worker', 'العمال'),
              ('partner', 'الشركاء'),
            ])
              ChoiceChip(
                selected: target == x.$1,
                label: Text(x.$2),
                onSelected: (_) => setState(() => target = x.$1),
              ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث بالطرف أو طريقة الدفع أو الصندوق',
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final x in rows.where(
                (x) =>
                    '${x['party_name']} ${x['method_name']} ${x['cashbox_name']}'
                        .contains(q),
              ))
                Card(
                  child: ListTile(
                    title: Text('${x['party_name']}'),
                    subtitle: Text(
                      '${x['date']} • ${x['method_name']} • ${x['cashbox_name']}',
                    ),
                    trailing: Wrap(
                      children: [
                        Text(
                          money(x['amount']),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          tooltip: 'إيصال',
                          onPressed: () async {
                            try {
                              await ReportService(
                                widget.r,
                              ).printPaymentReceipt(x['id'] as int);
                            } catch (e) {
                              msg(friendlyError(e));
                            }
                          },
                          icon: const Icon(Icons.receipt_long),
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
  );
}

class CashboxesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const CashboxesPage(this.r, {required this.userId, super.key});
  @override
  State<CashboxesPage> createState() => _CashboxesState();
}

class _CashboxesState extends State<CashboxesPage> {
  List<Map<String, Object?>> boxes = [], methods = [], transfers = [];

  Future<void> load() async {
    final a = await widget.r.cashboxes();
    final b = await widget.r.paymentMethods();
    final t = await widget.r.transfers();
    if (mounted)
      setState(() {
        boxes = a;
        methods = b;
        transfers = t;
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> addBox() async {
    final n = TextEditingController();
    final o = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'إضافة صندوق',
        children: [
          TextField(
            controller: n,
            decoration: const InputDecoration(labelText: 'اسم الصندوق *'),
          ),
          TextField(
            controller: o,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'الرصيد الافتتاحي'),
          ),
        ],
        onSave: () => Navigator.pop(context, n.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.createCashbox(
        name: n.text.trim(),
        openingBalance: int.tryParse(o.text) ?? 0,
        currency: 'YER',
        userId: widget.userId,
      ))) return;
      await load();
    }
  }

  Future<void> addMethod() async {
    final n = TextEditingController(),
        a = TextEditingController(),
        b = TextEditingController();
    String type = 'cash';
    int? cb = boxes.isEmpty ? null : boxes.first['id'] as int;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => FormDialog(
          title: 'إضافة طريقة دفع',
          children: [
            TextField(
              controller: n,
              decoration: const InputDecoration(labelText: 'اسم طريقة الدفع *'),
            ),
            DropdownButtonFormField<String>(
              value: type,
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('نقدي')),
                DropdownMenuItem(value: 'check', child: Text('شيك')),
                DropdownMenuItem(
                  value: 'bank_transfer',
                  child: Text('تحويل بنكي'),
                ),
                DropdownMenuItem(value: 'wallet', child: Text('محفظة')),
                DropdownMenuItem(value: 'other', child: Text('أخرى')),
              ],
              onChanged: (v) => s(() => type = v!),
              decoration: const InputDecoration(labelText: 'نوع الطريقة'),
            ),
            TextField(
              controller: a,
              decoration: const InputDecoration(labelText: 'رقم الحساب'),
            ),
            TextField(
              controller: b,
              decoration: const InputDecoration(labelText: 'اسم البنك'),
            ),
            DropdownButtonFormField<int>(
              value: cb,
              items: [
                for (final x in boxes)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ],
              onChanged: (v) => s(() => cb = v),
              decoration: const InputDecoration(labelText: 'الصندوق المرتبط'),
            ),
          ],
          onSave: () => Navigator.pop(c, n.text.trim().isNotEmpty),
        ),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.createPaymentMethod(
        name: n.text.trim(),
        type: type,
        cashboxId: cb,
        accountNumber: a.text,
        bankName: b.text,
        userId: widget.userId,
      ))) return;
      await load();
    }
  }

  Future<void> transfer() async {
    if (boxes.length < 2) {
      msg('يجب إنشاء صندوقين على الأقل');
      return;
    }
    int f = boxes.first['id'] as int;
    int t = boxes[1]['id'] as int;
    final a = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('تحويل بين الصناديق'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: f,
                items: [
                  for (final x in boxes)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => f = v!),
                decoration: const InputDecoration(labelText: 'من صندوق'),
              ),
              DropdownButtonFormField<int>(
                value: t,
                items: [
                  for (final x in boxes)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => t = v!),
                decoration: const InputDecoration(labelText: 'إلى صندوق'),
              ),
              TextField(
                controller: a,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(c, f != t && int.tryParse(a.text) != null),
              child: const Text('تحويل'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.transferCash(
          from: f,
          to: t,
          amount: int.parse(a.text),
          date: DateTime.now(),
          userId: widget.userId,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'الصناديق والتحويلات',
      subtitle: 'الأرصدة والتحويلات بين الصناديق وطرق الدفع',
      actions: [
        OutlinedButton.icon(
          onPressed: transfer,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('تحويل'),
        ),
        OutlinedButton.icon(
          onPressed: addMethod,
          icon: const Icon(Icons.payments),
          label: const Text('طريقة دفع'),
        ),
        FilledButton.icon(
          onPressed: addBox,
          icon: const Icon(Icons.account_balance),
          label: const Text('صندوق جديد'),
        ),
      ],
      child: ListView(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final x in boxes)
                Metric('${x['name']}', money(x['current_balance']), _blue),
            ],
          ),
          const SizedBox(height: 8),
          for (final x in boxes)
            ListTile(
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => RecordDetailsPage(
                    widget.r,
                    kind: 'cashbox',
                    id: x['id'] as int,
                    title: 'تفاصيل الصندوق',
                  ),
                ),
              ),
              title: Text('${x['name']}'),
              subtitle: Text('الرصيد الحالي: ${money(x['current_balance'])}'),
              trailing: const Icon(Icons.open_in_new),
            ),
          const SizedBox(height: 15),
          const Text(
            'طرق الدفع',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          for (final x in methods)
            ListTile(
              onTap: () => Navigator.push(
                c,
                MaterialPageRoute(
                  builder: (_) => RecordDetailsPage(
                    widget.r,
                    kind: 'payment_method',
                    id: x['id'] as int,
                    title: 'تفاصيل طريقة الدفع',
                  ),
                ),
              ),
              title: Text('${x['name']}'),
              subtitle: Text(
                '${paymentTypeName('${x['type']}')} • ${x['account_number'] ?? ''}',
              ),
              trailing: const Icon(Icons.open_in_new),
            ),
          const Divider(),
          const Text(
            'التحويلات',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          for (final x in transfers)
            ListTile(
              title: Text('${x['from_cashbox']} ← ${x['to_cashbox']}'),
              subtitle: Text('${x['date']}'),
              trailing: Text(money(x['amount'])),
            ),
        ],
      ),
    );
  }
}

class ExpensesPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const ExpensesPage(this.r, {required this.userId, super.key});
  @override
  State<ExpensesPage> createState() => _ExpensesState();
}

class _ExpensesState extends State<ExpensesPage> {
  List<Map<String, Object?>> rows = [];
  List<Map<String, Object?>> cash = [], methods = [];
  String q = '';
  Future<void> load() async {
    final a = await widget.r.expenses(),
        b = await widget.r.cashboxes(),
        m = await widget.r.paymentMethods();
    if (mounted)
      setState(() {
        rows = a;
        cash = b;
        methods = m;
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    String cat = 'other';
    int? cb = cash.isEmpty ? null : cash.first['id'] as int,
        pm = methods.isEmpty ? null : methods.first['id'] as int;
    final title = TextEditingController(),
        amount = TextEditingController(),
        note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة مصروف'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: cat,
                items: [
                  for (final x in [
                    'workers',
                    'partners',
                    'fuel',
                    'oil',
                    'grease',
                    'maintenance',
                    'parts',
                    'transport',
                    'admin',
                    'other',
                  ])
                    DropdownMenuItem(value: x, child: Text(categoryName(x))),
                ],
                onChanged: (v) => s(() => cat = v!),
                decoration: const InputDecoration(labelText: 'التصنيف'),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'بيان المصروف'),
              ),
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              DropdownButtonFormField<int>(
                value: pm,
                items: [
                  for (final x in methods)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => pm = v),
                decoration: const InputDecoration(labelText: 'طريقة الدفع'),
              ),
              DropdownButtonFormField<int>(
                value: cb,
                items: [
                  for (final x in cash)
                    DropdownMenuItem(
                      value: x['id'] as int,
                      child: Text('${x['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => cb = v),
                decoration: const InputDecoration(labelText: 'الصندوق'),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'ملاحظات'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                title.text.trim().isNotEmpty &&
                    int.tryParse(amount.text) != null &&
                    pm != null &&
                    cb != null,
              ),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.addExpense(
          category: cat,
          title: title.text,
          amount: int.parse(amount.text),
          date: DateTime.now(),
          paymentMethodId: pm!,
          cashboxId: cb!,
          userId: widget.userId,
          notes: note.text,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(c) => PageFrame(
    title: 'المصروفات',
    subtitle: 'تسجيل المصروفات مع التصنيف والصندوق والقيد المحاسبي',
    actions: [
      FilledButton.icon(
        onPressed: add,
        icon: const Icon(Icons.add),
        label: const Text('مصروف جديد'),
      ),
    ],
    child: Column(
      children: [
        TextField(
          onChanged: (v) => setState(() => q = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'بحث ببيان المصروف أو التصنيف',
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final x in rows.where(
                (x) => '${x['title']} ${x['category']}'.contains(q),
              ))
                Card(
                  child: ListTile(
                    title: Text('${x['title']}'),
                    subtitle: Text(
                      '${categoryName('${x['category']}')} • ${x['date']} • ${statusName(x['status'])}',
                    ),
                    trailing: Text(money(x['amount'])),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class WorkersPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const WorkersPage(this.r, {required this.userId, super.key});
  @override
  State<WorkersPage> createState() => _WorkersState();
}

class _WorkersState extends State<WorkersPage> {
  List<Map<String, Object?>> rows = [];
  String q = '';

  Future<void> load() async {
    final x = await widget.r.workers();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(), phone = TextEditingController();
    final rate = TextEditingController(),
        salary = TextEditingController(),
        percent = TextEditingController();
    String type = 'hourly';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة عامل'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'اسم العامل'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              DropdownButtonFormField<String>(
                value: type,
                items: const [
                  DropdownMenuItem(value: 'fixed', child: Text('راتب ثابت')),
                  DropdownMenuItem(value: 'hourly', child: Text('بالساعة')),
                  DropdownMenuItem(value: 'percentage', child: Text('نسبة')),
                ],
                onChanged: (v) => s(() => type = v!),
                decoration: const InputDecoration(labelText: 'طريقة الاستحقاق'),
              ),
              if (type == 'fixed')
                TextField(
                  controller: salary,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'الراتب'),
                ),
              if (type == 'hourly')
                TextField(
                  controller: rate,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'أجر الساعة'),
                ),
              if (type == 'percentage')
                TextField(
                  controller: percent,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'النسبة %'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, n.text.trim().isNotEmpty),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.createWorker(
        name: n.text,
        payType: type,
        fixedSalary: int.tryParse(salary.text) ?? 0,
        hourlyRate: int.tryParse(rate.text) ?? 0,
        percentageRate: double.tryParse(percent.text) ?? 0,
        userId: widget.userId,
      ))) return;
      await load();
    }
  }

  Future<void> transaction(Map<String, Object?> x) async {
    final a = TextEditingController(), h = TextEditingController();
    String type = 'accrual';
    final methods = await widget.r.paymentMethods();
    if (!mounted) return;
    final cashM = methods.where((m) => m['type'] == 'cash').toList();
    int? pm = (cashM.isNotEmpty ? cashM.first : (methods.isNotEmpty ? methods.first : null))?['id'] as int?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('حركة العامل: ${x['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: type,
                items: const [
                  DropdownMenuItem(
                    value: 'accrual',
                    child: Text('إضافة استحقاق'),
                  ),
                  DropdownMenuItem(value: 'payment', child: Text('دفع مستحق')),
                ],
                onChanged: (v) => s(() => type = v!),
                decoration: const InputDecoration(labelText: 'نوع الحركة'),
              ),
              if (type == 'payment' && methods.isNotEmpty)
                DropdownButtonFormField<int>(
                  value: pm,
                  items: [
                    for (final m in methods)
                      DropdownMenuItem(value: m['id'] as int, child: Text('${m['name']}')),
                  ],
                  onChanged: (v) => s(() => pm = v),
                  decoration: const InputDecoration(labelText: 'طريقة الدفع'),
                ),
              TextField(
                controller: a,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              TextField(
                controller: h,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'عدد الساعات'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, int.tryParse(a.text) != null),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.workerTransaction(
          workerId: x['id'] as int,
          type: type,
          amount: int.parse(a.text),
          hours: double.tryParse(h.text) ?? 0,
          paymentMethodId: type == 'payment' ? pm : null,
          userId: widget.userId,
        );
        await load();
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> editWorker(Map<String,Object?> x) async {
    final n=TextEditingController(text:'${x['name']??''}'), phone=TextEditingController(text:'${x['phone']??''}');
    String type='${x['pay_type']??'hourly'}';
    final rate=TextEditingController(text:'${x['hourly_rate']??0}'), salary=TextEditingController(text:'${x['fixed_salary']??0}'), pct=TextEditingController(text:'${x['percentage_rate']??0}');
    final ok=await showDialog<bool>(context:context,builder:(_) => StatefulBuilder(builder:(c,s)=>AlertDialog(title:const Text('تعديل معلومات العامل'),content:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:n,decoration:const InputDecoration(labelText:'الاسم')), TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف')),
      DropdownButtonFormField<String>(value:type,items:const [DropdownMenuItem(value:'fixed',child:Text('راتب ثابت')),DropdownMenuItem(value:'hourly',child:Text('بالساعة')),DropdownMenuItem(value:'percentage',child:Text('نسبة'))],onChanged:(v)=>s(()=>type=v!),decoration:const InputDecoration(labelText:'طريقة الاستحقاق')),
      if(type=='fixed') TextField(controller:salary,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'الراتب الثابت')),
      if(type=='hourly') TextField(controller:rate,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'أجر الساعة')),
      if(type=='percentage') TextField(controller:pct,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'النسبة %')),
    ]),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,n.text.trim().isNotEmpty),child:const Text('حفظ'))])));
    if(ok==true){await widget.r.updateWorker(x['id'] as int,{'name':n.text.trim(),'phone':phone.text,'pay_type':type,'fixed_salary':int.tryParse(salary.text)??0,'hourly_rate':int.tryParse(rate.text)??0,'percentage_rate':double.tryParse(pct.text)??0},widget.userId);await load();}
  }
  Future<void> deleteWorker(Map<String,Object?> x) async { final r=TextEditingController(); final ok=await showDialog<bool>(context:context,builder:(_)=>FormDialog(title:'حذف العامل',children:[const Text('سيتم إخفاؤه من القوائم دون حذف حركاته المحاسبية.'),TextField(controller:r,decoration:const InputDecoration(labelText:'سبب الحذف *'))],onSave:()=>Navigator.pop(context,r.text.trim().isNotEmpty))); if(ok==true){await widget.r.deleteWorker(x['id'] as int,widget.userId,r.text);await load();}}
  void workerActions(Map<String,Object?> x) { showModalBottomSheet(context:context,showDragHandle:true,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[ListTile(leading:const Icon(Icons.edit_outlined),title:const Text('تعديل معلومات العامل'),onTap:(){Navigator.pop(c);editWorker(x);}),ListTile(leading:const Icon(Icons.delete_outline,color:Colors.red),title:const Text('حذف'),onTap:(){Navigator.pop(c);deleteWorker(x);})]))); }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(q))
        .toList();
    return PageFrame(
      title: 'العمال',
      subtitle: 'الأجر بالساعة أو النسبة أو الراتب الثابت مع الاستحقاق والدفع',
      actions: [
        OutlinedButton.icon(onPressed: () => ReportService(widget.r).printPdf('worker_transactions'), icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('تقرير العمال')),
        FilledButton.icon(
          onPressed: add,
          icon: const Icon(Icons.person_add_alt),
          label: const Text('عامل جديد'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم العامل أو الهاتف',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا يوجد عمال مطابقون')
                : LayoutBuilder(builder: (_, box) {
                    final columns = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 720 ? 2 : 1;
                    final gap = 12.0;
                    final width = (box.maxWidth - gap * (columns - 1)) / columns;
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: filtered.map((x) {
                          final balance = (x['balance'] as num?)?.round() ?? 0;
                          return SizedBox(
                            width: width,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(24),
                              onTap: () => Navigator.push(
                                c,
                                MaterialPageRoute(
                                  builder: (_) => RecordDetailsPage(
                                    widget.r,
                                    kind: 'worker',
                                    id: x['id'] as int,
                                    title: 'تفاصيل العامل',
                                  ),
                                ),
                              ),
                              onLongPress: () => workerActions(x),
                              child: Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const CircleAvatar(child: Icon(Icons.engineering_rounded)),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '${x['name']}',
                                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            onSelected: (v) {
                                              if (v == 'edit') editWorker(x);
                                              if (v == 'delete') deleteWorker(x);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(value: 'edit', child: Text('تعديل معلومات المستخدم')),
                                              PopupMenuItem(value: 'delete', child: Text('حذف')),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        payTypeName('${x['pay_type']}'),
                                        style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        AccountingCalculations.balanceLabel(balance),
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                      const SizedBox(height: 12),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: OutlinedButton.icon(
                                          onPressed: () => transaction(x),
                                          icon: const Icon(Icons.account_balance_wallet_outlined),
                                          label: const Text('حركة العامل'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  }),
          ),
        ],
      ),
    );
  }
}

class PartnersPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  const PartnersPage(this.r, {required this.userId, super.key});
  @override
  State<PartnersPage> createState() => _PartnersState();
}

class _PartnersState extends State<PartnersPage> {
  List<Map<String, Object?>> rows = [];
  String q = '';

  Future<void> load() async {
    final x = await widget.r.partners();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> add() async {
    final n = TextEditingController(), phone = TextEditingController();
    final sh = TextEditingController(), pc = TextEditingController();
    String mode = 'percentage';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: const Text('إضافة شريك'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: n,
                decoration: const InputDecoration(labelText: 'اسم الشريك'),
              ),
              TextField(
                controller: phone,
                decoration: const InputDecoration(labelText: 'الهاتف'),
              ),
              DropdownButtonFormField<String>(
                value: mode,
                items: const [
                  DropdownMenuItem(
                    value: 'percentage',
                    child: Text('نسبة ملكية'),
                  ),
                  DropdownMenuItem(value: 'shares', child: Text('عدد حصص')),
                ],
                onChanged: (v) => s(() => mode = v!),
                decoration: const InputDecoration(labelText: 'طريقة الملكية'),
              ),
              if (mode == 'percentage')
                TextField(
                  controller: pc,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'النسبة %'),
                ),
              if (mode == 'shares')
                TextField(
                  controller: sh,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'عدد الحصص'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, n.text.trim().isNotEmpty),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      if (!await runGuarded(context, () => widget.r.createPartner(
        name: n.text,
        mode: mode,
        shares: int.tryParse(sh.text) ?? 0,
        percentage: double.tryParse(pc.text) ?? 0,
        phone: phone.text,
        userId: widget.userId,
      ))) return;
      await load();
    }
  }

  Future<void> share(Map<String, Object?> x) async {
    final amount = TextEditingController();
    final pct = TextEditingController(
      text: '${x['ownership_percentage'] ?? 0}',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: 'استحقاق حصة الشريك',
        children: [
          TextField(
            controller: amount,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'قيمة الاستحقاق'),
          ),
          TextField(
            controller: pct,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'النسبة المثبتة %'),
          ),
        ],
        onSave: () => Navigator.pop(
          context,
          int.tryParse(amount.text) != null && int.parse(amount.text) > 0,
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.createPartnerShare(
          partnerId: x['id'] as int,
          amount: int.parse(amount.text),
          date: DateTime.now(),
          percentage: double.tryParse(pct.text),
          userId: widget.userId,
        );
        await load();
        msg('تم تسجيل استحقاق الشريك والقيد المحاسبي');
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> pay(Map<String, Object?> x) async {
    final methods = await widget.r.paymentMethods();
    final cash = await widget.r.cashboxes();
    if (methods.isEmpty || cash.isEmpty) {
      msg('أضف طريقة دفع وصندوقًا أولًا');
      return;
    }
    int pm = methods.first['id'] as int;
    int cb = cash.first['id'] as int;
    final amount = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, s) => AlertDialog(
          title: Text('دفع مستحق: ${x['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'المبلغ'),
              ),
              DropdownButtonFormField<int>(
                value: pm,
                items: [
                  for (final m in methods)
                    DropdownMenuItem(
                      value: m['id'] as int,
                      child: Text('${m['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => pm = v!),
                decoration: const InputDecoration(labelText: 'طريقة الدفع'),
              ),
              DropdownButtonFormField<int>(
                value: cb,
                items: [
                  for (final b in cash)
                    DropdownMenuItem(
                      value: b['id'] as int,
                      child: Text('${b['name']}'),
                    ),
                ],
                onChanged: (v) => s(() => cb = v!),
                decoration: const InputDecoration(labelText: 'الصندوق'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                int.tryParse(amount.text) != null && int.parse(amount.text) > 0,
              ),
              child: const Text('دفع'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await widget.r.accounting.payPartner(
          partnerId: x['id'] as int,
          amount: int.parse(amount.text),
          paymentMethodId: pm,
          cashboxId: cb,
          userId: widget.userId,
        );
        await load();
        msg('تم دفع المستحق وتسجيل القيد');
      } catch (e) {
        msg(friendlyError(e));
      }
    }
  }

  Future<void> editPartner(Map<String,Object?> x) async {
    final n=TextEditingController(text:'${x['name']??''}'), phone=TextEditingController(text:'${x['phone']??''}'), pct=TextEditingController(text:'${x['ownership_percentage']??0}'), sh=TextEditingController(text:'${x['shares_count']??0}');
    String mode='${x['ownership_mode']??'percentage'}';
    final ok=await showDialog<bool>(context:context,builder:(_)=>StatefulBuilder(builder:(c,s)=>AlertDialog(title:const Text('تعديل معلومات الشريك'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:n,decoration:const InputDecoration(labelText:'الاسم')),TextField(controller:phone,decoration:const InputDecoration(labelText:'الهاتف')),DropdownButtonFormField<String>(value:mode,items:const [DropdownMenuItem(value:'percentage',child:Text('نسبة ملكية')),DropdownMenuItem(value:'shares',child:Text('عدد حصص'))],onChanged:(v)=>s(()=>mode=v!),decoration:const InputDecoration(labelText:'طريقة الملكية')),if(mode=='percentage')TextField(controller:pct,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'نسبة الملكية %')),if(mode=='shares')TextField(controller:sh,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'عدد الحصص'))]),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,n.text.trim().isNotEmpty),child:const Text('حفظ'))])));
    if(ok==true){await widget.r.updatePartner(x['id'] as int,{'name':n.text.trim(),'phone':phone.text,'ownership_mode':mode,'ownership_percentage':double.tryParse(pct.text)??0,'shares_count':int.tryParse(sh.text)??0},widget.userId);await load();}
  }
  Future<void> deletePartner(Map<String,Object?> x) async { final r=TextEditingController(); final ok=await showDialog<bool>(context:context,builder:(_)=>FormDialog(title:'حذف الشريك',children:[const Text('سيتم إخفاؤه من القوائم دون حذف حركاته المحاسبية.'),TextField(controller:r,decoration:const InputDecoration(labelText:'سبب الحذف *'))],onSave:()=>Navigator.pop(context,r.text.trim().isNotEmpty)));if(ok==true){await widget.r.deletePartner(x['id'] as int,widget.userId,r.text);await load();}}
  void partnerActions(Map<String,Object?> x){showModalBottomSheet(context:context,showDragHandle:true,builder:(c)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[ListTile(leading:const Icon(Icons.edit_outlined),title:const Text('تعديل معلومات الشريك'),onTap:(){Navigator.pop(c);editPartner(x);}),ListTile(leading:const Icon(Icons.delete_outline,color:Colors.red),title:const Text('حذف'),onTap:(){Navigator.pop(c);deletePartner(x);})])));}

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(BuildContext c) {
    final filtered = rows
        .where((x) => '${x['name']} ${x['phone'] ?? ''}'.contains(q))
        .toList();
    return PageFrame(
      title: 'الشركاء',
      subtitle: 'ملكية الشركاء وحصصهم واستحقاقاتهم ومدفوعاتهم',
      actions: [
        OutlinedButton.icon(onPressed: () => ReportService(widget.r).printPdf('partner_accounts'), icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('تقرير الشركاء')),
        FilledButton.icon(
          onPressed: add,
          icon: const Icon(Icons.group_add),
          label: const Text('شريك جديد'),
        ),
      ],
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'بحث باسم الشريك أو الهاتف',
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyView('لا يوجد شركاء مطابقون')
                : LayoutBuilder(builder: (_, box) {
                    final columns = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 720 ? 2 : 1;
                    final gap = 12.0;
                    final width = (box.maxWidth - gap * (columns - 1)) / columns;
                    return SingleChildScrollView(
                      child: Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: filtered.map((x) {
                          final balance = (x['balance'] as num?)?.round() ?? 0;
                          return SizedBox(
                            width: width,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(24),
                              onTap: () => Navigator.push(
                                c,
                                MaterialPageRoute(
                                  builder: (_) => RecordDetailsPage(
                                    widget.r,
                                    kind: 'partner',
                                    id: x['id'] as int,
                                    title: 'تفاصيل الشريك',
                                  ),
                                ),
                              ),
                              onLongPress: () => partnerActions(x),
                              child: Card(
                                margin: EdgeInsets.zero,
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const CircleAvatar(child: Icon(Icons.handshake_rounded)),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              '${x['name']}',
                                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            onSelected: (v) {
                                              if (v == 'edit') editPartner(x);
                                              if (v == 'delete') deletePartner(x);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(value: 'edit', child: Text('تعديل معلومات المستخدم')),
                                              PopupMenuItem(value: 'delete', child: Text('حذف')),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        x['ownership_mode'] == 'percentage'
                                            ? 'نسبة ملكية ${x['ownership_percentage'] ?? 0}%'
                                            : 'عدد حصص ${x['shares_count'] ?? 0}',
                                        style: TextStyle(color: Theme.of(c).colorScheme.onSurfaceVariant),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        AccountingCalculations.balanceLabel(balance),
                                        style: const TextStyle(fontWeight: FontWeight.w900),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: () => share(x),
                                              icon: const Icon(Icons.add_chart),
                                              label: const Text('استحقاق'),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: () => pay(x),
                                              icon: const Icon(Icons.payments),
                                              label: const Text('دفع'),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    );
                  }),
          ),
        ],
      ),
    );
  }
}

class JournalPage extends StatefulWidget {
  final StationRepository r;
  const JournalPage(this.r, {super.key});
  @override
  State<JournalPage> createState() => _JournalState();
}

class _JournalState extends State<JournalPage> {
  List<Map<String, Object?>> rows = [];
  Future<void> load() async {
    final x = await widget.r.journal();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'دفتر اليومية',
      subtitle: 'كل القيود المحاسبية المتوازنة المرتبطة بالعمليات',
      actions: [
        OutlinedButton.icon(
          onPressed: load,
          icon: const Icon(Icons.refresh),
          label: const Text('تحديث'),
        ),
      ],
      child: rows.isEmpty
          ? const EmptyView('لا توجد قيود')
          : ListView(
              children: [
                for (final x in rows)
                  Card(
                    child: ListTile(
                      onTap: () => Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => RecordDetailsPage(
                            widget.r,
                            kind: 'journal',
                            id: x['journal_id'] as int,
                            title: 'تفاصيل القيد المحاسبي',
                          ),
                        ),
                      ),
                      title: Text('${x['description']}'),
                      subtitle: Text(
                        '${x['date']} • ${x['account_code']} ${x['account_name']}',
                      ),
                      trailing: Text('مدين ${x['debit']}\nدائن ${x['credit']}'),
                    ),
                  ),
              ],
            ),
    );
  }
}

class LedgerPage extends StatefulWidget {
  final StationRepository r;
  const LedgerPage(this.r, {super.key});
  @override
  State<LedgerPage> createState() => _LedgerState();
}

class _LedgerState extends State<LedgerPage> {
  String code = '1000';
  List<Map<String, Object?>> rows = [];
  final accounts = const {
    '1000': 'الصندوق',
    '1100': 'التحويلات',
    '1200': 'ذمم المستفيدين',
    '1300': 'مخزون الديزل',
    '2100': 'مستحقات العمال',
    '2200': 'مستحقات الشركاء',
    '4000': 'إيرادات السقي',
    '4010': 'إيرادات الديزل',
    '5000': 'مصروف العمال',
    '5010': 'مصروف الوقود',
    '5020': 'الزيت والشحم',
    '5030': 'الصيانة',
  };
  Future<void> load() async {
    final x = await widget.r.ledger(code);
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'الأستاذ العام',
      subtitle: 'حساب مستقل لكل رمز مع المدين والدائن',
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            value: code,
            items: [
              for (final e in accounts.entries)
                DropdownMenuItem(
                  value: e.key,
                  child: Text('${e.key} • ${e.value}'),
                ),
            ],
            onChanged: (v) {
              if (v != null) {
                code = v;
                load();
              }
            },
            decoration: const InputDecoration(labelText: 'الحساب'),
          ),
          Expanded(
            child: rows.isEmpty
                ? const EmptyView('لا توجد حركات لهذا الحساب')
                : ListView(
                    children: [
                      for (final x in rows)
                        Card(
                          child: ListTile(
                            title: Text('${x['description']}'),
                            subtitle: Text('${x['date']} • ${x['memo'] ?? ''}'),
                            trailing: Text(
                              'مدين ${x['debit']} / دائن ${x['credit']}',
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class ReportsPage extends StatefulWidget {
  final StationRepository r;
  const ReportsPage(this.r, {super.key});
  static const keys = [
    'irrigations',
    'cash_flow',
    'time_comparison',
    'monthly_financial',
    'income',
    'payment_methods',
    'expenses',
    'cashboxes',
    'queue_bookings',
    'payment_log',
    'beneficiary_statement',
    'beneficiary_detailed',
    'beneficiary_stats',
    'needy',
    'diesel_inventory',
    'activity_overview',
    'oil_status',
    'debts',
    'beneficiary_list',
    'revenue_comparison',
    'system_comparison',
    'journal',
    'ledger',
    'worker_transactions',
    'partner_accounts',
  ];
  @override
  State<ReportsPage> createState() => _ReportsState();
}

class _ReportsState extends State<ReportsPage> {
  List<Map<String, Object?>> bs = [], ws = [], ps = [], cs = [], ms = [];
  DateTime? from, to;
  String? type, category, status;
  int? bid, wid, pid, cid, mid;
  String currentType = 'diesel';
  Future<void> load() async {
    final a = await widget.r.beneficiaries(),
        b = await widget.r.workers(),
        p = await widget.r.partners(),
        c = await widget.r.cashboxes(),
        m = await widget.r.paymentMethods();
    final sysType = (await widget.r.settings())['system_type'] ?? 'diesel';
    if (mounted)
      setState(() {
        bs = a;
        ws = b;
        ps = p;
        cs = c;
        ms = m;
        currentType = sysType;
        type = 'all';
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> previewR(String k) async {
    if (currentType == 'solar' && k == 'diesel_inventory') return;
    try {
      final rows = await widget.r.report(
      k,
      from: from,
      to: to,
      beneficiaryId: bid,
      workerId: wid,
      partnerId: pid,
      systemType: type,
      cashboxId: cid,
      paymentMethodId: mid,
      category: category,
      status: status,
      );
      if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReportPreviewPage(
          widget.r,
          keyName: k,
          rows: rows,
          filters: '${from ?? ''} ${to ?? ''}',
          from: from, to: to, beneficiaryId: bid, workerId: wid, partnerId: pid,
          cashboxId: cid, paymentMethodId: mid, systemType: type, category: category, status: status,
        ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إنشاء التقرير: $e')),
        );
      }
    }
  }

  Future<void> printR(String k) async {
    try {
      await ReportService(widget.r).printPdf(
        k,
        from: from,
        to: to,
        beneficiaryId: bid,
        workerId: wid,
        partnerId: pid,
        systemType: type,
        cashboxId: cid,
        paymentMethodId: mid,
        category: category,
        status: status,
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget sel<T>(
    String label,
    T? v,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> f,
  ) => SizedBox(
    width: 205,
    child: DropdownButtonFormField<T>(
      value: v,
      items: items,
      onChanged: f,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(c) => PageFrame(
    title: 'التقارير والطباعة',
    subtitle: '25 تقريرًا ببيانات قاعدة البيانات مع فلاتر قبل الطباعة',
    child: ListView(
      children: [
        SectionCard(
          title: 'الفلاتر',
          icon: Icons.filter_alt,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  from = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    initialDate: from ?? DateTime.now(),
                    locale: const Locale('ar'),
                  );
                  setState(() {});
                },
                icon: const Icon(Icons.date_range),
                label: Text(
                  from == null
                      ? 'من تاريخ'
                      : 'من ${from!.year}/${from!.month}/${from!.day}',
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  to = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    initialDate: to ?? DateTime.now(),
                    locale: const Locale('ar'),
                  );
                  setState(() {});
                },
                icon: const Icon(Icons.date_range),
                label: Text(
                  to == null
                      ? 'إلى تاريخ'
                      : 'إلى ${to!.year}/${to!.month}/${to!.day}',
                ),
              ),
              sel<String>('نوع المنظومة', type, [
                const DropdownMenuItem(value: 'all', child: Text('كل الأنواع')),
                if (currentType == 'diesel') const DropdownMenuItem(value: 'diesel', child: Text('ديزل')),
                if (currentType == 'solar') const DropdownMenuItem(value: 'solar', child: Text('شمسي')),
                if (currentType == 'equivalent_hybrid') const DropdownMenuItem(value: 'equivalent_hybrid', child: Text('النوع الثالث')),
              ], (v) => setState(() => type = v)),
              sel<int>('المستفيد', bid, [
                const DropdownMenuItem(
                  value: null,
                  child: Text('كل المستفيدين'),
                ),
                for (final x in bs)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ], (v) => setState(() => bid = v)),
              sel<int>('العامل', wid, [
                const DropdownMenuItem(value: null, child: Text('كل العمال')),
                for (final x in ws)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ], (v) => setState(() => wid = v)),
              sel<int>('الشريك', pid, [
                const DropdownMenuItem(value: null, child: Text('كل الشركاء')),
                for (final x in ps)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ], (v) => setState(() => pid = v)),
              sel<int>('الصندوق', cid, [
                const DropdownMenuItem(value: null, child: Text('كل الصناديق')),
                for (final x in cs)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ], (v) => setState(() => cid = v)),
              sel<int>('طريقة الدفع', mid, [
                const DropdownMenuItem(
                  value: null,
                  child: Text('كل طرق الدفع'),
                ),
                for (final x in ms)
                  DropdownMenuItem(
                    value: x['id'] as int,
                    child: Text('${x['name']}'),
                  ),
              ], (v) => setState(() => mid = v)),
              sel<String>('تصنيف المصروف', category, [
                const DropdownMenuItem(
                  value: null,
                  child: Text('كل التصنيفات'),
                ),
                for (final x in [
                  'workers',
                  'partners',
                  'fuel',
                  'oil',
                  'grease',
                  'maintenance',
                  'parts',
                  'transport',
                  'admin',
                  'other',
                ])
                  DropdownMenuItem(value: x, child: Text(categoryName(x))),
              ], (v) => setState(() => category = v)),
              sel<String>('الحالة', status, [
                const DropdownMenuItem(value: null, child: Text('كل الحالات')),
                for (final x in ['posted', 'cancelled', 'new', 'scheduled'])
                  DropdownMenuItem(value: x, child: Text(statusName(x))),
              ], (v) => setState(() => status = v)),
            ],
          ),
        ),
        const SizedBox(height: 10),
        for (final k in ReportsPage.keys)
          Card(
            child: ListTile(
              title: Text(ReportService.titles[k] ?? 'تقرير'),
              trailing: Wrap(
                children: [
                  IconButton(
                    tooltip: 'معاينة التقرير',
                    onPressed: () => previewR(k),
                    icon: const Icon(Icons.visibility),
                  ),
                  FilledButton.icon(
                    onPressed: () => printR(k),
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة التقرير'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

String? reportFieldArabic(String key) => {
  'id':'الرقم','date':'التاريخ','start_datetime':'بداية السقي','end_datetime':'نهاية السقي','minutes':'المدة بالدقائق','system_type':'نوع المنظومة','total_amount':'الإجمالي','paid_amount':'المدفوع','remaining':'حالة الرصيد','beneficiary_name':'المستفيد','party_name':'الجهة','cloud_status':'حالة خصم الغيم','worker_name':'العامل','partner_name':'الشريك','cashbox_name':'الصندوق','method_name':'طريقة الدفع','account_name':'الحساب','account_code':'رمز الحساب','debit':'مدين','credit':'دائن','amount':'المبلغ','liters':'اللترات','kind':'نوع الحركة','status':'الحالة','notes':'ملاحظات','description':'البيان','ownership_percentage':'نسبة الملكية','shares_count':'عدد الحصص','opening_balance':'الرصيد الافتتاحي','carried_balance':'الرصيد المرحل','balance':'حالة الرصيد','water_amount':'قيمة المياه','diesel_amount':'قيمة الديزل','cloud_minutes':'دقائق الغيم','chargeable_minutes':'الدقائق المحاسبية','category':'التصنيف','title':'العنوان','phone':'الهاتف','name':'الاسم','reference_number':'رقم المرجع','created_at':'تاريخ الإنشاء','updated_at':'تاريخ التحديث','position':'الدور','scheduled_start':'بداية الموعد','scheduled_end':'نهاية الموعد','payment_method_id':'طريقة الدفع','cashbox_id':'الصندوق','beneficiary_id':'المستفيد','worker_id':'العامل','partner_id':'الشريك','journal_id':'رقم القيد','journal_entry_id':'رقم القيد','ownership_mode':'طريقة الملكية',}[key];
String reportValueArabic(String key, Object? value) {
  if (value == null) return '-';
  if (key == 'system_type') return systemName('$value');
  if (key == 'status') return statusName(value);
  if (key == 'kind') return movementName('$value');
  if (key == 'ownership_mode') return value == 'percentage' ? 'نسبة ملكية' : 'عدد حصص';
  return '$value';
}

class ReportPreviewPage extends StatelessWidget {
  final StationRepository r;
  final String keyName;
  final List<Map<String, Object?>> rows;
  final String filters;
  final DateTime? from, to;
  final int? beneficiaryId, workerId, partnerId, cashboxId, paymentMethodId;
  final String? systemType, category, status;
  const ReportPreviewPage(
    this.r, {
    required this.keyName,
    required this.rows,
    required this.filters,
    this.from, this.to, this.beneficiaryId, this.workerId, this.partnerId,
    this.cashboxId, this.paymentMethodId, this.systemType, this.category, this.status,
    super.key,
  });

  @override
  Widget build(BuildContext c) {
    final title = ReportService.titles[keyName] ?? 'تقرير';
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          actions: [
            FilledButton.icon(
              onPressed: () async {
                await ReportService(r).printPdf(keyName, from: from, to: to, beneficiaryId: beneficiaryId, workerId: workerId, partnerId: partnerId, cashboxId: cashboxId, paymentMethodId: paymentMethodId, systemType: systemType, category: category, status: status);
              },
              icon: const Icon(Icons.print),
              label: const Text('طباعة'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            SectionCard(
              title: 'معاينة التقرير',
              icon: Icons.description,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'عدد السجلات: ${rows.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (filters.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('الفلاتر: $filters'),
                    ),
                  const SizedBox(height: 8),
                  if (rows.isEmpty)
                    const EmptyView('لا توجد بيانات مطابقة للفلاتر المحددة')
                  else
                    for (final x in rows.take(200))
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final e in x.entries.where((e) => reportFieldArabic(e.key) != null))
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 3),
                                  child: Text('${reportFieldArabic(e.key)}: ${reportValueArabic(e.key, e.value)}'),
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

class NotificationsPage extends StatefulWidget {
  final StationRepository r;
  const NotificationsPage(this.r, {super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsState();
}

class _NotificationsState extends State<NotificationsPage> {
  List<Map<String, Object?>> rows = [];
  String snoozeNote(Map<String, Object?> x) {
    final until = DateTime.tryParse('${x['snoozed_until'] ?? ''}');
    return until != null && until.isAfter(DateTime.now())
        ? '\nمؤجّل حتى ${until.toString().substring(0, 16)}'
        : '';
  }

  Future<void> load() async {
    final x = await widget.r.notifications();
    if (mounted) setState(() => rows = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'الإشعارات',
    subtitle: 'تنبيهات المستفيدين وحالات القراءة',
    child: rows.isEmpty
        ? const EmptyView('لا توجد إشعارات')
        : ListView(
            children: [
              for (final x in rows)
                Card(
                  child: ListTile(
                    onTap: () async {
                      if (!await runGuarded(context, () => widget.r.markNotificationRead(x['id'] as int))) return;
                      load();
                    },
                    leading: Icon(
                      x['read_at'] == null
                          ? Icons.notifications_active
                          : Icons.notifications_none,
                      color: x['read_at'] == null ? _cyan : null,
                    ),
                    title: Text('${x['title']}'),
                    subtitle: Text('${x['body']}\n${x['created_at']}${snoozeNote(x)}'),
                    trailing: PopupMenuButton<int>(
                      tooltip: 'تأجيل التنبيه',
                      icon: const Icon(Icons.snooze_rounded),
                      onSelected: (m) async {
                        if (!await runGuarded(context, () => widget.r.snoozeNotification(x['id'] as int, minutes: m))) return;
                        await load();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 10, child: Text('10 دقائق')),
                        PopupMenuItem(value: 60, child: Text('ساعة')),
                        PopupMenuItem(value: 1440, child: Text('يوم')),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}

class SettingsPage extends StatefulWidget {
  final StationRepository r;
  final int userId;
  final ValueChanged<String>? onSystemTypeChanged;
  const SettingsPage(this.r, {required this.userId, this.onSystemTypeChanged, super.key});
  @override
  State<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsPage> {
  Map<String, String> s = {};

  Future<void> load() async {
    final x = await widget.r.settings();
    if (mounted) setState(() => s = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> edit(String key, String label, {bool numeric = false, String? preset}) async {
    final c = TextEditingController(text: preset ?? s[key] ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => FormDialog(
        title: label,
        children: [
          TextField(
            controller: c,
            keyboardType: numeric ? TextInputType.number : null,
            decoration: InputDecoration(labelText: label),
          ),
        ],
        onSave: () => Navigator.pop(context, c.text.trim().isNotEmpty),
      ),
    );
    if (ok == true) {
      if (key == 'system_type') {
        if (!await runGuarded(context, () => widget.r.setSystemType(c.text))) return;
        widget.onSystemTypeChanged?.call(c.text);
      } else {
        if (!await runGuarded(context, () => widget.r.setSetting(key, c.text))) return;
      }
      await load();
    }
  }

  Future<void> users() async {
    final x = await AdminService(widget.r.db).users();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('المستخدمون'),
        content: SizedBox(
          width: 450,
          height: 360,
          child: ListView(
            children: [
              for (final u in x)
                ListTile(
                  title: Text('${u['name']}'),
                  subtitle: Text(
                    '${u['username']} • ${roleArabic('${u['role']}')}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String roleArabic(String x) =>
      {
        'manager': 'مدير',
        'accountant': 'محاسب',
        'operations': 'تشغيل',
        'beneficiary': 'مستفيد',
      }[x] ??
      'مستخدم';

  Future<void> close() async {
    try {
      await AdminService(widget.r.db).closePeriod(
        stationId: 1,
        start: DateTime(DateTime.now().year, 1, 1),
        end: DateTime.now(),
        userId: widget.userId,
        notes: 'إغلاق من الإعدادات',
      );
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إغلاق الفترة وتسجيل العملية')),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _pumpSettingTile() => ListTile(
    title: const Text('المضخة المستخدمة في السقي'),
    subtitle: Text(s['pump_name'] ?? 'غير محددة'),
    trailing: const Icon(Icons.arrow_drop_down),
    onTap: () async {
      final pumps = await widget.r.db.query('pumps', where: 'active=1', orderBy: 'id');
      if (!mounted) return;
      final v = await showDialog<int>(context: context, builder: (d) => SimpleDialog(
        title: const Text('اختيار المضخة المستخدمة'),
        children: [
          for (final p in pumps)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(d, p['id'] as int),
              child: Text('${p['name']} • ${systemName('${p['system_type']}')}'),
            ),
        ],
      ));
      if (v != null) {
        if (!await runGuarded(context, () => widget.r.selectPump(v))) return;
        await load();
        widget.onSystemTypeChanged?.call(s['system_type'] ?? 'diesel');
      }
    },
  );

  Widget setTile(String k, String label, [bool n = false]) => ListTile(
    title: Text(label),
    subtitle: Text(settingDisplay(k, s[k] ?? 'غير مضبوط')),
    trailing: const Icon(Icons.edit),
    onTap: () => edit(k, label, numeric: n),
  );
  Widget boolTile(String k, String label) => SwitchListTile.adaptive(
    title: Text(label), value: (s[k] ?? 'false') == 'true',
    onChanged: (v) async { if (!await runGuarded(context, () => widget.r.setSetting(k, v ? 'true' : 'false'))) return; await load(); },
    secondary: const Icon(Icons.toggle_on_outlined), contentPadding: const EdgeInsets.symmetric(horizontal: 16),
  );
  Widget dropdownTile(String k, String label, List<MapEntry<String,String>> options) => ListTile(
    title: Text(label), subtitle: Text(settingDisplay(k, s[k] ?? 'غير مضبوط')),
    trailing: const Icon(Icons.keyboard_arrow_down_rounded),
    onTap: () async {
      final current=s[k];
      final v=await showDialog<String>(context:context,builder:(d)=>SimpleDialog(title:Text(label),children:[for(final o in options)SimpleDialogOption(onPressed:()=>Navigator.pop(d,o.key),child:Row(children:[if(o.key==current)const Icon(Icons.check_rounded,size:18),const SizedBox(width:8),Text(o.value)]))]));
      if(v!=null){if (!await runGuarded(context, () => widget.r.setSetting(k,v))) return;await load();}
    },
  );

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      title: 'الإعدادات',
      subtitle: 'إعداد المحطة والمضخة والتسعير والطابور والتنبيهات',
      actions: [
        OutlinedButton.icon(
          onPressed: users,
          icon: const Icon(Icons.people_alt),
          label: const Text('المستخدمون'),
        ),
        FilledButton.icon(
          onPressed: close,
          icon: const Icon(Icons.lock_clock),
          label: const Text('إغلاق الفترة'),
        ),
      ],
      child: ListView(
        children: [
          SettingGroup(
            title: 'بيانات المحطة',
            children: [
              setTile('station_name', 'اسم المحطة'),
              _pumpSettingTile(),
              setTile('address', 'العنوان'),
              setTile('phone', 'الهاتف'),
              setTile('currency', 'العملة'),
              setTile('timezone', 'المنطقة الزمنية'),
              setTile('app_name', 'اسم التطبيق'),
              setTile('station_logo_path', 'مسار شعار المحطة'),
              setTile('app_icon_path', 'مسار أيقونة التطبيق'),
            ],
          ),
          SettingGroup(
            title: 'المنظومة والتسعير',
            children: [
              ListTile(
                title: const Text('نوع المنظومة'),
                subtitle: Text(settingDisplay('system_type', s['system_type'] ?? 'diesel')),
                trailing: const Icon(Icons.arrow_drop_down),
                onTap: () async {
                  final v = await showDialog<String>(context: c, builder: (d) => SimpleDialog(
                    title: const Text('اختيار نوع المنظومة'),
                    children: [
                      SimpleDialogOption(onPressed: () => Navigator.pop(d, 'diesel'), child: const Text('ديزل')),
                      SimpleDialogOption(onPressed: () => Navigator.pop(d, 'solar'), child: const Text('شمسي')),
                      SimpleDialogOption(onPressed: () => Navigator.pop(d, 'equivalent_hybrid'), child: const Text('النوع الثالث')),
                    ],
                  ));
                  if (v != null) {
                    if (!await runGuarded(context, () => widget.r.setSystemType(v))) return;
                    widget.onSystemTypeChanged?.call(v);
                    await load();
                  }
                },
              ),
              if ((s['system_type'] ?? 'diesel') == 'diesel') ...[
                setTile('diesel_hourly_water_rate', 'سعر مياه الديزل بالساعة', true),
                setTile('diesel_liters_per_hour', 'لترات الديزل في الساعة', true),
                setTile('diesel_price_per_liter', 'سعر لتر الديزل', true),
              ],
              if ((s['system_type'] ?? 'diesel') == 'solar')
                setTile('solar_hourly_rate', 'سعر السقي الشمسي بالساعة', true),
              if ((s['system_type'] ?? 'diesel') == 'equivalent_hybrid')
                setTile('third_type_hourly_rate', 'سعر النوع الثالث بالساعة', true),
              setTile('partial_hour', 'محاسبة الجزء من الساعة'),
              setTile('rounding', 'سياسة التقريب'),
            ],
          ),
          SettingGroup(
            title: 'الطابور والجلسات',
            children: [
              dropdownTile('queue_type', 'نمط التشغيل', const [MapEntry('circular','طابور دائري'),MapEntry('booking','نظام حجز')]),
              dropdownTile('time_source', 'مصدر الوقت', const [MapEntry('device','وقت الجهاز'),MapEntry('server','وقت الخادم')]),
              setTile('min_wait_days', 'الحد الأدنى لأيام الانتظار', true),
              boolTile('manager_override_required', 'اشتراط تجاوز المدير'),
              dropdownTile('absence_policy', 'سياسة الغياب', const [MapEntry('postpone','تأجيل'),MapEntry('cancel','إلغاء'),MapEntry('keep','إبقاء الدور')]),
              boolTile('allow_midnight_crossing', 'السماح بعبور منتصف الليل'),
            ],
          ),
          SettingGroup(
            title: 'قنوات الإشعارات وقوالبها',
            children: [
              boolTile('sound_notifications', 'التنبيهات الصوتية'),
              boolTile('popup_notifications', 'النوافذ المنبثقة'),
              FilledButton.tonalIcon(onPressed: () async { final ok=await DeviceNotificationSettings.open(); if(!ok&&mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('إعدادات إشعارات الجهاز متاحة على أندرويد من زر الإشعارات في إعدادات التطبيق.'))); }, icon: const Icon(Icons.notifications_active_outlined), label: const Text('إدارة إشعارات التطبيق من إعدادات الجهاز')),
              setTile('notification_appointment_title', 'عنوان إشعار الموعد'),
              setTile('notification_appointment_body', 'نص إشعار الموعد'),
              setTile('notification_payment_title', 'عنوان إشعار الدفع'),
              setTile('notification_payment_body', 'نص إشعار الدفع'),
              setTile('notification_balance_title', 'عنوان إشعار الرصيد'),
              setTile('notification_balance_body', 'نص إشعار الرصيد'),
            ],
          ),
          SettingGroup(
            title: 'التنبيهات والتقارير',
            children: [
              if ((s['system_type'] ?? 'diesel') == 'diesel') ...[
                setTile('diesel_warning_percent', 'نسبة تنبيه الديزل', true),
                setTile('diesel_snooze_minutes', 'مدة تأجيل تنبيه الديزل بالدقائق', true),
              ],
              setTile('pdf_rows', 'عدد الصفوف الافتراضي في التقرير', true),
              boolTile('reduced_motion', 'تقليل الحركة'),
            ],
          ),
        ],
      ),
    );
  }
}

class SettingGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const SettingGroup({required this.title, required this.children, super.key});
  @override
  Widget build(BuildContext c) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ExpansionTile(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
      children: children,
    ),
  );
}

class PerformancePage extends StatefulWidget {
  final StationRepository r;
  const PerformancePage(this.r, {super.key});
  @override
  State<PerformancePage> createState() => _PerformanceState();
}

class _PerformanceState extends State<PerformancePage> {
  List<Map<String, Object?>> reports = [], metrics = [];
  Future<void> load() async {
    final a = await widget.r.db.query(
      'report_runs',
      orderBy: 'generated_at DESC',
      limit: 30,
    );
    final b = await widget.r.db.query(
      'performance_metrics',
      orderBy: 'opened_at DESC',
      limit: 30,
    );
    if (mounted)
      setState(() {
        reports = a;
        metrics = b;
      });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  Widget build(c) => PageFrame(
    title: 'قياس الأداء',
    subtitle: 'زمن فتح الشاشة والاستعلام وإنشاء التقارير',
    actions: [
      OutlinedButton.icon(
        onPressed: load,
        icon: const Icon(Icons.refresh),
        label: const Text('تحديث'),
      ),
    ],
    child: ListView(
      children: [
        SectionCard(
          title: 'آخر التقارير',
          icon: Icons.picture_as_pdf,
          child: reports.isEmpty
              ? const EmptyView('لا توجد قياسات تقارير بعد')
              : Column(
                  children: [
                    for (final x in reports)
                      ListTile(
                        title: Text(
                          ReportService.titles['${x['report_key'] ?? ''}'] ??
                              'تقرير',
                        ),
                        subtitle: Text(
                          '${x['generated_at'] ?? '-'} • ${x['row_count'] ?? 0} صف',
                        ),
                        trailing: Text('${x['duration_ms'] ?? 0} مللي ثانية'),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'قياسات الشاشة والاستعلام',
          icon: Icons.speed,
          child: metrics.isEmpty
              ? const EmptyView('لا توجد قياسات شاشة بعد')
              : Column(
                  children: [
                    for (final x in metrics)
                      ListTile(
                        title: Text(
                          'فتح الشاشة: ${x['screen'] ?? '-'}',
                        ),
                        subtitle: Text(
                          '${x['opened_at'] ?? '-'} • استعلام ${x['query_ms'] ?? 0} مللي ثانية',
                        ),
                        trailing: Text('${x['open_ms'] ?? 0} مللي ثانية'),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}

class BackupPage extends StatefulWidget {
  final StationRepository r;
  const BackupPage(this.r, {super.key});
  @override
  State<BackupPage> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> {
  List<Map<String, Object?>> history = [];
  bool busy = false;
  Future<void> load() async {
    final x = await BackupService(widget.r.accounting).history();
    if (mounted) setState(() => history = x);
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> backup() async {
    setState(() => busy = true);
    try {
      await BackupService(widget.r.accounting).createAndShare();
      await load();
    } catch (e) {
      msg(friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore() async {
    setState(() => busy = true);
    try {
      final x = await BackupService(
        widget.r.accounting,
      ).pickAndRestoreDatabase();
      msg(
        x['restored'] == true
            ? 'تم الاسترجاع بنجاح'
            : x['cancelled'] == true
            ? 'تم الإلغاء'
            : x['error'] ?? 'تعذر الاسترجاع',
      );
      await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void msg(String x) {
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(x)));
  }

  @override
  Widget build(c) => PageFrame(
    title: 'النسخ الاحتياطي والاستعادة',
    subtitle: 'نسخة قابلة للتحقق مع سجل عمليات النسخ والاستعادة',
    child: ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : backup,
                icon: const Icon(Icons.backup),
                label: const Text('إنشاء نسخة'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () async {
                  setState(() => busy = true);
                  try {
                    final path = await BackupService(widget.r.accounting).saveBackupToLocation();
                    if (path != null) msg('تم حفظ النسخة الاحتياطية بنجاح');
                  } catch (e) { msg(friendlyError(e)); }
                  finally { if (mounted) setState(() => busy = false); }
                },
                icon: const Icon(Icons.save_alt),
                label: const Text('حفظ نسخة'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : restore,
                icon: const Icon(Icons.restore),
                label: const Text('استعادة نسخة'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'السجل',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        ...history.map(
          (x) => Card(
            child: ListTile(
              title: Text(statusName(x['status'])),
              subtitle: Text('${x['created_at']}\n${x['path']}'),
            ),
          ),
        ),
      ],
    ),
  );
}
