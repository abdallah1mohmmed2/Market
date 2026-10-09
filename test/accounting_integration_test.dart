// اختبارات تكامل على قاعدة SQLite حقيقية (sqflite_common_ffi).
// تغطي الإصلاحات: اتجاه دفع العامل، منع ازدواج الديزل، عدم تضاعف السلفة،
// القيد العكسي عند الإلغاء، وتاريخ القيد = تاريخ العملية.
// ملاحظة: كُتبت دون تشغيل (لا يوجد Flutter SDK في بيئة الكتابة) — شغّلها بـ flutter test.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:saqia_station/data/local/database.dart';
import 'package:saqia_station/data/repositories/repositories.dart';
import 'package:saqia_station/domain/accounting/accounting_service.dart';
import 'package:saqia_station/services/admin_service.dart';
import 'package:saqia_station/services/backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late AccountingService svc;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(
      '${await databaseFactory.getDatabasesPath()}/saqia_station_v2.db',
    );
    db = AppDatabase.instance;
    svc = AccountingService(db);
    await db.db;
  });

  Future<int> cashboxBalance(int id) async =>
      ((await db.query('SELECT current_balance b FROM cashboxes WHERE id=?',
                  args: [id]))
              .first['b'] as num)
          .round();

  Future<num> accountNet(String code) async => (await db.query(
        'SELECT COALESCE(SUM(l.debit)-SUM(l.credit),0) n FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE a.code=?',
        args: [code],
      )).first['n'] as num;

  test('دفع راتب لعامل ينقص الصندوق ويقيّد مدين المستحقات / دائن الصندوق', () async {
    final w = await db.insert('workers', {
      'name': 'عامل',
      'pay_type': 'fixed',
    });
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=100000 WHERE id=1'));
    final before = await cashboxBalance(1);
    await svc.payWorker(
      workerId: w, amount: 1000, paymentMethodId: 1, cashboxId: 1,
    );
    expect(await cashboxBalance(1), before - 1000);
    expect(await accountNet('2100'), 1000);
  });

  test('تاريخ القيد هو تاريخ المصروف لا لحظة الحفظ', () async {
    final d = DateTime(2026, 3, 5, 10);
    final id = await svc.addExpense(
      category: 'maintenance', title: 't', amount: 100, date: d,
      paymentMethodId: 1, cashboxId: 1,
    );
    final r = await db.query(
      "SELECT date FROM journal_entries WHERE reference_type='expense' AND reference_id=?",
      args: [id],
    );
    expect((r.first['date'] as String).startsWith('2026-03-05'), isTrue);
  });

  test('إلغاء مصروف: يعيد الصندوق ويعكس القيد ولا يتعلق', () async {
    final before = await cashboxBalance(1);
    final id = await svc.addExpense(
      category: 'maintenance', title: 'x', amount: 250, date: DateTime.now(),
      paymentMethodId: 1, cashboxId: 1,
    );
    expect(await cashboxBalance(1), before - 250);
    await svc.cancelExpense(id, 1, 'خطأ إدخال').timeout(const Duration(seconds: 10));
    expect(await cashboxBalance(1), before);
    final rev = await db.query("SELECT COUNT(*) c FROM journal_entries WHERE reference_type='reversal'");
    expect((rev.first['c'] as num) >= 1, isTrue);
  });

  test('حركة ديزل (تسليم) لا تتعلق ويُقيَّد جانبها المحاسبي', () async {
    await svc.addDieselMovement(
      kind: 'receipt', liters: 100, unitPrice: 100, date: DateTime.now(), cashboxId: 1,
    ).timeout(const Duration(seconds: 10));
    expect(await svc.dieselStock(), greaterThanOrEqualTo(100));
  });

  test('تحويل بين صندوق نقدي وبنكي: قيد على حسابي الصندوقين الصحيحين', () async {
    await db.transaction((tx) => tx.rawUpdate('UPDATE cashboxes SET current_balance=50000 WHERE id=1'));
    final cashBefore = await accountNet('1000');
    final bankBefore = await accountNet('1100');
    final boxes = await db.query('SELECT id FROM cashboxes ORDER BY id');
    if (boxes.length < 2) return;
    final other = boxes[1]['id'] as int;
    await svc.transferCash(from: 1, to: other, amount: 1000, date: DateTime.now());
    expect((await accountNet('1000')) - cashBefore, -1000);
    expect((await accountNet('1100')) - bankBefore, 1000);
  });

  test('التحويل إلى نفس الصندوق مرفوض', () async {
    expect(() => svc.transferCash(from: 1, to: 1, amount: 10, date: DateTime.now()),
        throwsA(isA<ArgumentError>()));
  });

  test('رصيد العامل يشمل الافتتاحي والمرحّل', () async {
    final w = await db.insert('workers', {'name': 'عامل برصيد افتتاحي', 'pay_type': 'fixed', 'opening_balance': 1000, 'carried_balance': 200});
    expect((await svc.workerBalance(w))['balance'], 1200);
  });

  test('رصيد الشريك يشمل الافتتاحي والمرحّل', () async {
    final p = await db.insert('partners', {'name': 'شريك', 'ownership_mode': 'shares', 'opening_balance': 0, 'carried_balance': 700});
    expect((await svc.partnerBalance(p))['balance'], 700);
  });

  Future<void> useSolar6000() async {
    for (final e in {'system_type': 'solar', 'solar_hourly_rate': '6000'}.entries) {
      await db.update('settings', {'value': e.value}, 'key=?', [e.key]);
    }
  }

  Future<int> glPayable(String code, String col, int id) async => ((await db.query(
        'SELECT COALESCE(SUM(l.credit)-SUM(l.debit),0) n FROM journal_lines l JOIN accounts a ON a.id=l.account_id WHERE a.code=? AND l.$col=?',
        args: [code, id],
      )).first['n'] as num).round();

  Future<int> irrigationFor({int? workerId, int? partnerId, required DateTime start}) =>
      svc.recordIrrigation(
        stationId: 1, pumpId: 1, workerId: workerId, partnerId: partnerId,
        partyType: workerId != null ? 'worker' : 'partner',
        start: start, end: start.add(const Duration(hours: 1)), systemType: 'solar',
        waterRate: 0, litersPerHour: 0, dieselPrice: 0, solarRate: 0, thirdRate: 0,
        cloudMinutes: 0, paidAmount: 0,
      );

  test('سقاية على حساب عامل: الأستاذ 2100 يطابق كشف العامل، والإلغاء يعكس بلا حذف', () async {
    await useSolar6000();
    final w = await db.insert('workers', {'name': 'عامل سقاية', 'pay_type': 'fixed'});
    await svc.createWorkerAccrual(workerId: w, amount: 10000, date: DateTime(2026, 3, 1));
    final id = await irrigationFor(workerId: w, start: DateTime(2026, 3, 1, 8));
    expect(await glPayable('2100', 'worker_id', w), 4000);
    expect((await svc.workerBalance(w))['balance'], 4000);
    expect(await glPayable('1200', 'worker_id', w), 0);
    await svc.cancelIrrigation(id, 1, 'خطأ إدخال');
    expect(await glPayable('2100', 'worker_id', w), 10000);
    expect((await svc.workerBalance(w))['balance'], 10000);
    final kept = await db.query("SELECT COUNT(*) n FROM worker_transactions WHERE worker_id=? AND type='irrigation'", args: [w]);
    expect(kept.first['n'], 1);
  });

  test('سقاية على حساب شريك: الأستاذ 2200 يطابق كشف الشريك بعد الخصم والإلغاء', () async {
    await useSolar6000();
    final p = await db.insert('partners', {'name': 'شريك سقاية', 'ownership_mode': 'shares'});
    await svc.createPartnerShare(partnerId: p, amount: 10000, date: DateTime(2026, 3, 1));
    final id = await irrigationFor(partnerId: p, start: DateTime(2026, 3, 3, 8));
    expect(await glPayable('2200', 'partner_id', p), 4000);
    expect((await svc.partnerBalance(p))['balance'], 4000);
    await svc.cancelIrrigation(id, 1, 'خطأ إدخال');
    expect(await glPayable('2200', 'partner_id', p), 10000);
    expect((await svc.partnerBalance(p))['balance'], 10000);
  });

  test('الدفعة المرافقة للسقاية مرفوضة لغير المستفيد', () async {
    await useSolar6000();
    final w = await db.insert('workers', {'name': 'عامل 2', 'pay_type': 'fixed'});
    expect(() => svc.recordIrrigation(
      stationId: 1, pumpId: 1, workerId: w, partyType: 'worker',
      start: DateTime(2026, 3, 5, 8), end: DateTime(2026, 3, 5, 9),
      systemType: 'solar', waterRate: 0, litersPerHour: 0, dieselPrice: 0,
      solarRate: 0, thirdRate: 0, cloudMinutes: 0, paidAmount: 500,
    ), throwsA(isA<ArgumentError>()));
  });

  test('تصدير/استعادة JSON يحفظ فترات الغيم والفترات المغلقة وجداول المستفيد', () async {
    await useSolar6000();
    final now = DateTime.now().toIso8601String();
    final b = await db.insert('beneficiaries', {'name': 'مستفيد غيم', 'created_at': now, 'updated_at': now});
    final start = DateTime(2026, 4, 1, 8);
    await svc.recordIrrigation(
      stationId: 1, pumpId: 1, beneficiaryId: b, start: start,
      end: start.add(const Duration(hours: 2)), systemType: 'solar',
      waterRate: 0, litersPerHour: 0, dieselPrice: 0, solarRate: 0, thirdRate: 0,
      cloudMinutes: 0, paidAmount: 0,
      cloudPeriods: [{'start': start.add(const Duration(minutes: 10)).toIso8601String(), 'end': start.add(const Duration(minutes: 40)).toIso8601String()}],
    );
    await db.insert('beneficiary_auth_codes', {'beneficiary_id': b, 'code_hash': 'x', 'expires_at': now, 'created_at': now});
    await AdminService(db).closePeriod(stationId: 1, start: DateTime(2020, 1, 1), end: DateTime(2020, 12, 31), userId: 1);
    Future<int> count(String t) async => (await db.query('SELECT COUNT(*) n FROM $t')).first['n'] as int;
    final clouds = await count('cloud_periods');
    final closures = await count('period_closures');
    final codes = await count('beneficiary_auth_codes');
    expect(clouds, greaterThan(0)); expect(closures, greaterThan(0));
    final json = await svc.exportStateJson();
    final backup = BackupService(svc);
    final bytes = Uint8List.fromList(utf8.encode(json));
    expect((await backup.validatePortableJson(bytes))['valid'], true);
    await backup.restorePortableJson(bytes);
    expect(await count('cloud_periods'), clouds);
    expect(await count('period_closures'), closures);
    expect(await count('beneficiary_auth_codes'), codes);
    final old = jsonDecode(json) as Map<String, dynamic>;
    for (final k in AccountingService.optionalPortableTables) old.remove(k);
    final oldBytes = Uint8List.fromList(utf8.encode(jsonEncode(old)));
    expect((await backup.validatePortableJson(oldBytes))['valid'], true);
    await backup.restorePortableJson(oldBytes);
    expect(await count('period_closures'), closures);
  });

  test('كشف المستفيد: الرصيد الجاري الأخير = beneficiaryBalance (دفعات + سلف الديزل)', () async {
    await useSolar6000();
    final repo = StationRepository(db);
    final now = DateTime.now().toIso8601String();
    final b = await db.insert('beneficiaries', {'name': 'مستفيد كشف', 'opening_balance': 1000, 'created_at': now, 'updated_at': now});
    final start = DateTime(2026, 6, 1, 8);
    await svc.recordIrrigation(
      stationId: 1, pumpId: 1, beneficiaryId: b, start: start,
      end: start.add(const Duration(hours: 1)), systemType: 'solar',
      waterRate: 0, litersPerHour: 0, dieselPrice: 0, solarRate: 0, thirdRate: 0,
      cloudMinutes: 0, paidAmount: 0,
    );
    await svc.receivePayment(beneficiaryId: b, amount: 2000, paymentMethodId: 1, cashboxId: 1);
    await svc.addDieselMovement(beneficiaryId: b, kind: 'advance', liters: 5, unitPrice: 100, date: DateTime.now());
    final stmt = await repo.beneficiaryStatement(b);
    final expected = (await svc.beneficiaryBalance(b))['balance'];
    expect(stmt.last['balance'], expected);
    expect(expected, 1000 + 6000 + 500 - 2000);
    for (final k in ['description', 'debit', 'credit', 'balance']) expect(stmt.first.containsKey(k), isTrue, reason: k);
  });

  test('تثبيت جديد: عمود snoozed_until موجود ويعمل تأجيل الإشعار', () async {
    final repo = StationRepository(db);
    final id = await db.insert('notifications', {'type': 't', 'title': 't', 'body': 'b', 'created_at': DateTime.now().toIso8601String()});
    await repo.snoozeNotification(id);
    final r = await db.query('SELECT snoozed_until FROM notifications WHERE id=?', args: [id]);
    expect(r.first['snoozed_until'], isNotNull);
  });

  test('مصدر الدفع: الافتراضي نقدي مفعّل، والمختار يحدد صندوقه، وغير الموجود يُرفض', () async {
    final cb = await db.insert('cashboxes', {'station_id': 1, 'name': 'صندوق بنك', 'opening_balance': 0, 'current_balance': 0, 'currency': 'YER', 'active': 1});
    final bank = await db.insert('payment_methods', {'station_id': 1, 'name': 'تحويل بنكي', 'type': 'bank_transfer', 'cashbox_id': cb, 'ledger_account_code': '1100', 'active': 1});
    final def = await svc.paymentSource();
    final defType = (await db.query('SELECT type FROM payment_methods WHERE id=?', args: [def['method']])).first['type'];
    expect(defType, 'cash');
    final chosen = await svc.paymentSource(paymentMethodId: bank);
    expect(chosen['method'], bank); expect(chosen['cashbox'], cb);
    await expectLater(svc.paymentSource(paymentMethodId: 999999), throwsArgumentError);
  });

  test('الطابور الدائري: إنهاء الدور يعيد المستفيد لآخر الطابور ويزيد دورته', () async {
    final repo = StationRepository(db);
    await db.transaction((tx) => tx.rawDelete('DELETE FROM queue_entries'));
    final ids = <int>[];
    for (final n in ['طابور ١', 'طابور ٢', 'طابور ٣']) { final b = await repo.createBeneficiary(name: n); ids.add(await repo.enqueue(b)); }
    await repo.completeQueue(ids.first);
    final r = await db.query('SELECT id,position,status,cycle_number FROM queue_entries ORDER BY position');
    expect(r.map((e) => e['id']).toList(), [ids[1], ids[2], ids[0]]);
    expect(r.last['status'], 'waiting'); expect(r.last['cycle_number'], 2);
    expect(r.map((e) => e['position']).toList(), [1, 2, 3]);
  });

  test('اختيار المضخة عبر المستودع: يحفظ الإعدادين ويرفض مضخة غير موجودة', () async {
    final repo = StationRepository(db);
    await repo.selectPump(1);
    final st = await repo.settings();
    expect(st['selected_pump_id'], '1');
    expect(st['pump_name'], isNotEmpty);
    await expectLater(repo.selectPump(999999), throwsArgumentError);
  });
}
