import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'calculations.dart';
import '../../data/local/database.dart';
import '../../data/local/queue_rotation.dart';

/// رصيد ديزل المستفيد (لترات) = افتتاحي + مرحّل + تسليم + سلف − استهلاك.
/// السلف داخلة في الرصيد حتى لا يبقى الرصيد سالبًا فتتضاعف السلفة التالية.
/// مخزون المحطة (لترات).
const String _stationDieselStockSql =
    "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements";

const String _beneficiaryDieselStockSql =
    "SELECT COALESCE((SELECT opening_diesel_liters FROM beneficiaries WHERE id=?),0)"
    "+COALESCE((SELECT carried_diesel_liters FROM beneficiaries WHERE id=?),0)"
    "+COALESCE((SELECT SUM(CASE WHEN kind IN ('delivery','advance') THEN liters WHEN kind='consumption' THEN -liters ELSE 0 END) FROM diesel_movements WHERE beneficiary_id=?),0) stock";

class AccountingService {
  final AppDatabase database;
  AccountingService([AppDatabase? db]) : database = db ?? AppDatabase.instance;

  Future<int> _accountIdTx(Transaction tx, String code) async {
    final r = await tx.query(
      'accounts',
      columns: ['id'],
      where: 'code=?',
      whereArgs: [code],
      limit: 1,
    );
    if (r.isEmpty) throw StateError('الحساب غير موجود: $code');
    return r.first['id'] as int;
  }

  Future<int> _entry(
    Transaction tx, {
    required String description,
    required String referenceType,
    int? referenceId,
    required List<Map<String, Object?>> lines,
    int? userId,
    DateTime? date,
  }) async {
    final debit = lines.fold<int>(
      0,
      (s, x) => s + ((x['debit'] as num?)?.round() ?? 0),
    );
    final credit = lines.fold<int>(
      0,
      (s, x) => s + ((x['credit'] as num?)?.round() ?? 0),
    );
    if (debit != credit)
      throw StateError('القيد غير متوازن: المدين $debit / الدائن $credit');
    if (debit < 0 || credit < 0 || lines.isEmpty)
      throw StateError('القيد المحاسبي غير صالح');
    final now = DateTime.now().toIso8601String();
    // تاريخ القيد = تاريخ العملية الفعلي (وليس لحظة الحفظ) حتى لا تُرحَّل
    // الحركات القديمة إلى اليوم ولا يُتجاوز إغلاق الفترة.
    final id = await tx.insert('journal_entries', {
      'date': (date ?? DateTime.now()).toIso8601String(),
      'reference_type': referenceType,
      'reference_id': referenceId,
      'description': description,
      'status': 'posted',
      'created_by': userId,
      'created_at': now,
    });
    for (final line in lines)
      await tx.insert('journal_lines', {...line, 'journal_entry_id': id});
    return id;
  }

  Future<Map<String, String>> settings() async {
    final r = await database.query('SELECT key,value FROM settings');
    return {for (final x in r) x['key'] as String: x['value'] as String};
  }

  Future<bool> _settingBool(String key, {bool fallback = false}) async =>
      (await settings())[key]?.toLowerCase() == 'true' ? true : fallback;


  /// يعكس كل القيود المرحّلة المرتبطة بمرجع معيّن بقيد عكسي (مدين↔دائن).
  /// لا يعدّل القيد الأصلي؛ يبقى مرحّلاً ويُلغى أثره بقيد عكسي مرحّل.
  /// آمن للاستدعاء مرتين: القيد الذي له عكس سابق يُتجاوز.
  Future<int> _reverseEntriesTx(
    Transaction tx, {
    required String referenceType,
    required int referenceId,
    required String reason,
    int? userId,
  }) async {
    final entries = await tx.rawQuery(
      "SELECT je.id,je.description FROM journal_entries je WHERE je.reference_type=? AND je.reference_id=? AND je.status='posted' "
      "AND NOT EXISTS (SELECT 1 FROM journal_entries r WHERE r.reference_type='reversal' AND r.reference_id=je.id)",
      [referenceType, referenceId],
    );
    var n = 0;
    for (final e in entries) {
      final eid = e['id'] as int;
      final lines = await tx.query(
        'journal_lines',
        where: 'journal_entry_id=?',
        whereArgs: [eid],
      );
      await _entry(
        tx,
        description: 'عكس قيد رقم $eid: ${e['description']} — $reason',
        referenceType: 'reversal',
        referenceId: eid,
        lines: [
          for (final l in lines)
            {
              'account_id': l['account_id'],
              'beneficiary_id': l['beneficiary_id'],
              'worker_id': l['worker_id'],
              'partner_id': l['partner_id'],
              'debit': l['credit'],
              'credit': l['debit'],
              'memo': 'عكس: ${l['memo'] ?? ''}',
            },
        ],
        userId: userId,
      );
      n++;
    }
    return n;
  }

  Future<void> _assertPeriodOpen(Transaction tx, DateTime date) async {
    final rows = await tx.rawQuery(
      "SELECT id FROM period_closures WHERE period_start<=? AND period_end>=? LIMIT 1",
      [date.toIso8601String(), date.toIso8601String()],
    );
    if (rows.isNotEmpty)
      throw StateError('الفترة المحاسبية مغلقة ولا يمكن إضافة حركة إليها');
  }

  Future<int> _checkWaiting(
    Transaction tx,
    int beneficiaryId,
    DateTime start, {
    required int minDays,
    required bool override,
    String? reason,
    int? userId,
  }) async {
    // نفحص أقرب سقاية سابقة وأقرب سقاية لاحقة للتاريخ المُدخل، فالإدخال بتاريخ
    // قديم لا يُرفض خطأً بسبب سقاية أحدث، وفي المقابل لا يُسمح بسقاية قريبة جدًا
    // قبل سقاية لاحقة مسجلة.
    final startIso = start.toIso8601String();
    final prev = await tx.rawQuery(
      "SELECT MAX(start_datetime) d FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime<=?",
      [beneficiaryId, startIso],
    );
    final next = await tx.rawQuery(
      "SELECT MIN(start_datetime) d FROM irrigations WHERE beneficiary_id=? AND status!='cancelled' AND start_datetime>?",
      [beneficiaryId, startIso],
    );
    final prevV = prev.first['d'], nextV = next.first['d'];
    if (prevV == null && nextV == null) return 0;
    var elapsed = 1 << 30;
    if (prevV != null) {
      elapsed = start.difference(DateTime.parse(prevV as String)).inDays;
    }
    if (nextV != null) {
      final gap = DateTime.parse(nextV as String).difference(start).inDays;
      if (gap < elapsed) elapsed = gap;
    }
    if (elapsed < minDays && override) {
      if (reason == null || reason.trim().isEmpty)
        throw StateError('يجب إدخال سبب تجاوز مدة الانتظار');
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'waiting_period_override',
        table: 'irrigations',
        recordId: null,
        reason: reason,
      );
      return 1;
    }
    return 0;
  }

  /// يحدد طريقة الدفع والصندوق: ما اختاره المستخدم إن وُجد، وإلا أول طريقة نقدية مفعّلة
  /// وصندوقها المرتبط. تُستخدم بدل القيم الثابتة 1/1.
  Future<Map<String, int>> resolvePaymentSource(
    DatabaseExecutor ex, {
    int? paymentMethodId,
    int? cashboxId,
  }) async {
    final m = paymentMethodId != null
        ? await ex.rawQuery(
            'SELECT id,cashbox_id FROM payment_methods WHERE id=? AND active=1',
            [paymentMethodId],
          )
        : await ex.rawQuery(
            "SELECT id,cashbox_id FROM payment_methods WHERE active=1 ORDER BY CASE WHEN type='cash' THEN 0 ELSE 1 END, id LIMIT 1",
          );
    if (m.isEmpty) {
      throw ArgumentError(paymentMethodId != null
          ? 'طريقة الدفع غير موجودة أو غير مفعّلة'
          : 'لا توجد طريقة دفع مفعّلة');
    }
    var cb = cashboxId ?? (m.first['cashbox_id'] as num?)?.toInt();
    if (cb == null) {
      final c = await ex.rawQuery(
        'SELECT id FROM cashboxes WHERE active=1 ORDER BY id LIMIT 1',
      );
      if (c.isEmpty) throw ArgumentError('لا يوجد صندوق مفعّل');
      cb = (c.first['id'] as num).toInt();
    } else {
      final c = await ex.rawQuery(
        'SELECT id FROM cashboxes WHERE id=? AND active=1',
        [cb],
      );
      if (c.isEmpty) throw ArgumentError('الصندوق غير موجود أو غير مفعّل');
    }
    return {'method': (m.first['id'] as num).toInt(), 'cashbox': cb};
  }

  Future<Map<String, int>> paymentSource({
    int? paymentMethodId,
    int? cashboxId,
  }) async => resolvePaymentSource(
    await database.db,
    paymentMethodId: paymentMethodId,
    cashboxId: cashboxId,
  );

  Future<int> recordIrrigation({
    required int stationId,
    required int pumpId,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    String partyType = 'beneficiary',
    required DateTime start,
    required DateTime end,
    required String systemType,
    required int waterRate,
    required double litersPerHour,
    required int dieselPrice,
    required int solarRate,
    required int thirdRate,
    required int cloudMinutes,
    List<Map<String, String>> cloudPeriods = const [],
    required int paidAmount,
    int? paymentMethodId,
    int? cashboxId,
    int? bookingId,
    int? queueId,
    int? sessionId,
    int? userId,
    bool overrideWaitingPeriod = false,
    String? overrideReason,
    String? notes,
  }) async {
    if ((partyType == 'beneficiary' && beneficiaryId == null) ||
        (partyType == 'worker' && workerId == null) ||
        (partyType == 'partner' && partnerId == null)) {
      throw ArgumentError('يجب تحديد صاحب حساب السقاية');
    }
    if (paidAmount < 0) throw ArgumentError('المبلغ المدفوع لا يمكن أن يكون سالبًا');
    // الدفعة المرافقة للسقاية تخص المستفيد فقط؛ العامل/الشريك يُسدَّد حسابهما من شاشة الدفع.
    if (paidAmount > 0 && partyType != 'beneficiary')
      throw ArgumentError('الدفعة المرافقة للسقاية متاحة للمستفيد فقط');
    final set = await settings();
    final configuredPumpId = int.tryParse(set['selected_pump_id'] ?? '');
    if (configuredPumpId == null) throw StateError('لا توجد مضخة محددة في الإعدادات');
    final pumpRows = await database.query(
      'SELECT id,station_id,active FROM pumps WHERE id=? LIMIT 1',
      args: [configuredPumpId],
    );
    if (pumpRows.isEmpty || pumpRows.first['active'] != 1)
      throw StateError('المضخة المحددة في الإعدادات غير موجودة أو غير فعالة');
    if (pumpRows.first['station_id'] != stationId)
      throw StateError('المضخة المحددة لا تتبع المحطة الحالية');
    if (pumpId != configuredPumpId)
      throw StateError('يجب استخدام المضخة المحددة في الإعدادات فقط');

    // نوع المنظومة مركزي: لا نثق بقيمة الشاشة أو المضخة القادمة من الواجهة.
    final effectiveType = set['system_type'] ?? 'diesel';
    const allowedTypes = {'diesel', 'solar', 'equivalent_hybrid'};
    if (!allowedTypes.contains(effectiveType))
      throw StateError('نوع المنظومة في الإعدادات غير صالح');

    // الأسعار أيضًا تؤخذ من الإعدادات لحظة التسجيل حتى يكون السعر Snapshot موحدًا.
    final effectiveWaterRate = int.tryParse(set['diesel_hourly_water_rate'] ?? '0') ?? 0;
    final effectiveLiters = double.tryParse(set['diesel_liters_per_hour'] ?? '0') ?? 0;
    final effectiveDieselPrice = int.tryParse(set['diesel_price_per_liter'] ?? '0') ?? 0;
    final effectiveSolarRate = int.tryParse(set['solar_hourly_rate'] ?? '0') ?? 0;
    final effectiveThirdRate = int.tryParse(set['third_type_hourly_rate'] ?? '0') ?? 0;
    final allowMidnight = set['allow_midnight_crossing'] == 'true';
    // عبور منتصف الليل: تُنقل النهاية لليوم التالي قبل أي فحص أو حفظ، حتى لا يُحفظ
    // end_datetime أصغر من البداية فيفسد فحص التعارض والتقارير.
    final endDt = (allowMidnight && !end.isAfter(start))
        ? end.add(const Duration(days: 1))
        : end;
    final normalizedCloudPeriods = <Map<String, Object?>>[];
    if (effectiveType == 'solar' && cloudPeriods.isNotEmpty) {
      final parsed = <Map<String, Object?>>[];
      for (final period in cloudPeriods) {
        final ps = DateTime.tryParse(period['start'] ?? '');
        final pe = DateTime.tryParse(period['end'] ?? '');
        if (ps == null || pe == null || !pe.isAfter(ps)) {
          throw ArgumentError('فترة الغيم يجب أن تحتوي وقت بداية ونهاية صحيحين');
        }
        if (ps.isBefore(start) || pe.isAfter(endDt)) {
          throw ArgumentError('فترة الغيم يجب أن تقع داخل وقت السقاية');
        }
        parsed.add({'start': ps, 'end': pe, 'minutes': pe.difference(ps).inMinutes});
      }
      parsed.sort((a,b) => (a['start'] as DateTime).compareTo(b['start'] as DateTime));
      for (var i=1; i<parsed.length; i++) {
        if ((parsed[i]['start'] as DateTime).isBefore(parsed[i-1]['end'] as DateTime)) {
          throw ArgumentError('فترات الغيم لا يجوز أن تتداخل');
        }
      }
      final totalCloud = parsed.fold<int>(0, (sum, x) => sum + x['minutes'] as int);
      if (totalCloud > AccountingCalculations.minutesBetween(start, endDt, allowMidnightCrossing: allowMidnight)) {
        throw ArgumentError('إجمالي خصم الغيم لا يمكن أن يتجاوز مدة السقاية');
      }
      for (final x in parsed) {
        normalizedCloudPeriods.add({
          'start': (x['start'] as DateTime).toIso8601String(),
          'end': (x['end'] as DateTime).toIso8601String(),
          'minutes': x['minutes'],
        });
      }
    }
    final effectiveCloud = effectiveType == 'solar'
        ? (normalizedCloudPeriods.isNotEmpty
            ? normalizedCloudPeriods.fold<int>(0, (sum, x) => sum + (x['minutes'] as int))
            : cloudMinutes.clamp(0, AccountingCalculations.minutesBetween(start, endDt, allowMidnightCrossing: allowMidnight)))
        : 0;
    final rounding = set['rounding'] ?? 'nearest';
    final partialHour = set['partial_hour'] != 'false';
    final calc = effectiveType == 'diesel'
        ? AccountingCalculations.diesel(
            start: start,
            end: endDt,
            hourlyWaterRate: effectiveWaterRate,
            litersPerHour: effectiveLiters,
            dieselPrice: effectiveDieselPrice,
            cloudMinutes: 0,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          )
        : effectiveType == 'solar'
        ? AccountingCalculations.solar(
            start: start,
            end: endDt,
            hourlyRate: effectiveSolarRate,
            cloudMinutes: effectiveCloud,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          )
        : AccountingCalculations.equivalent(
            start: start,
            end: endDt,
            hourlyRate: effectiveThirdRate,
            allowMidnightCrossing: allowMidnight,
            rounding: rounding,
            partialHour: partialHour,
          );

    return database.transaction((tx) async {
      await _assertPeriodOpen(tx, start);
      if (sessionId != null) {
        final sess = await tx.query(
          'irrigation_sessions',
          columns: ['status'],
          where: 'id=?',
          whereArgs: [sessionId],
          limit: 1,
        );
        if (sess.isEmpty || sess.first['status'] != 'running')
          throw StateError('الجلسة غير موجودة أو ليست قيد التشغيل');
      }
      final overlap = await tx.rawQuery(
        "SELECT id FROM irrigations WHERE pump_id=? AND status!='cancelled' AND start_datetime<? AND end_datetime>? LIMIT 1",
        [pumpId, endDt.toIso8601String(), start.toIso8601String()],
      );
      if (overlap.isNotEmpty) throw StateError('يوجد تعارض زمني على المضخة');
      final minDays = int.tryParse(set['min_wait_days'] ?? '3') ?? 3;
      final override = partyType == 'beneficiary'
          ? await _checkWaiting(
              tx,
              beneficiaryId!,
              start,
              minDays: minDays,
              override: overrideWaitingPeriod,
              reason: overrideReason,
              userId: userId,
            )
          : (overrideWaitingPeriod ? 1 : 0);
      // ---- ديزل المستفيد: حساب العجز مرة واحدة قبل إنشاء الفاتورة ----
      // سياسة منع الازدواج:
      //  * إن كان تسليم الديزل رصيدًا ماليًا (له) يُحمَّل كامل ثمن الوقود ويُخصم الرصيد عند التسليم.
      //  * وإلا يُحمَّل ثمن العجز فقط (الكمية التي لم يغطها ديزله العيني).
      var chargedDiesel = calc.dieselAmount;
      var shortageLiters = 0.0;
      if (partyType == 'beneficiary' &&
          effectiveType == 'diesel' &&
          calc.dieselLiters > 0) {
        final br = await tx.rawQuery(_beneficiaryDieselStockSql, [
          beneficiaryId,
          beneficiaryId,
          beneficiaryId,
        ]);
        final available = (br.first['stock'] as num?)?.toDouble() ?? 0;
        shortageLiters = calc.dieselLiters > available
            ? calc.dieselLiters - available
            : 0;
        final financialCredit =
            (set['diesel_delivery_financial_credit'] ?? '').toLowerCase() ==
            'true';
        if (!financialCredit) {
          chargedDiesel = AccountingCalculations.roundAmount(
            shortageLiters * effectiveDieselPrice,
            rounding,
          );
        }
      }
      final totalCharged = calc.waterAmount + chargedDiesel;
      final now = DateTime.now().toIso8601String();
      final id = await tx.insert('irrigations', {
        'station_id': stationId,
        'pump_id': pumpId,
        'beneficiary_id': beneficiaryId,
        'worker_id': workerId,
        'partner_id': partnerId,
        'party_type': partyType,
        'booking_id': bookingId,
        'queue_entry_id': queueId,
        'session_id': sessionId,
        'date': start.toIso8601String().substring(0, 10),
        'start_datetime': start.toIso8601String(),
        'end_datetime': endDt.toIso8601String(),
        'minutes': calc.minutes,
        'system_type': effectiveType,
        'water_hourly_rate_snapshot': effectiveWaterRate,
        'diesel_liters_per_hour_snapshot': effectiveLiters,
        'diesel_price_snapshot': effectiveDieselPrice,
        'solar_hourly_rate_snapshot': effectiveSolarRate,
        'third_type_hourly_rate_snapshot': effectiveThirdRate,
        'cloud_minutes': calc.cloudMinutes,
        'chargeable_minutes': calc.chargeableMinutes,
        'water_amount': calc.waterAmount,
        'diesel_amount': chargedDiesel,
        'total_amount': totalCharged,
        'paid_amount': paidAmount,
        'status': 'posted',
        'override_waiting_period': override,
        'override_reason': overrideReason,
        'created_by': userId,
        'created_at': now,
        'updated_at': now,
        'notes': notes,
      });
      for (final period in normalizedCloudPeriods) {
        await tx.insert('cloud_periods', {
          'irrigation_id': id,
          'start_datetime': period['start'],
          'end_datetime': period['end'],
          'minutes': period['minutes'],
          'created_at': now,
        });
      }
      // حساب الطرف في الأستاذ يطابق كشفه الفرعي:
      // مستفيد → ذمم المستفيدين 1200، عامل → مستحقات العمال 2100، شريك → مستحقات الشركاء 2200.
      // (كان العامل/الشريك يُقيَّد على 1200 بينما كشفهما يخصم السقاية من 2100/2200).
      final receivable = await _accountIdTx(
        tx,
        partyType == 'worker'
            ? '2100'
            : partyType == 'partner'
            ? '2200'
            : '1200',
      );
      final waterRevenue = await _accountIdTx(tx, '4000');
      final fuelRevenue = await _accountIdTx(tx, '4010');
      final lines = <Map<String, Object?>>[
        {
          'account_id': receivable,
          'beneficiary_id': beneficiaryId,
          'worker_id': workerId,
          'partner_id': partnerId,
          'debit': totalCharged,
          'credit': 0,
          'memo': partyType == 'beneficiary' ? 'استحقاق سقاية' : 'خصم سقاية من مستحقات الطرف',
        },
      ];
      if (calc.waterAmount > 0)
        lines.add({
          'account_id': waterRevenue,
          'debit': 0,
          'credit': calc.waterAmount,
          'memo': 'إيراد السقي',
        });
      if (chargedDiesel > 0)
        lines.add({
          'account_id': fuelRevenue,
          'debit': 0,
          'credit': chargedDiesel,
          'memo': 'قيمة ديزل السقي',
        });
      await _entry(
        tx,
        description: 'سقاية رقم $id',
        referenceType: 'irrigation',
        referenceId: id,
        lines: lines,
        userId: userId,
        date: start,
      );
      if (partyType == 'worker') {
        await tx.insert('worker_transactions', {
          'worker_id': workerId,
          'date': now,
          'type': 'irrigation',
          'amount': totalCharged,
          'reference_type': 'irrigation',
          'reference_id': id,
          'notes': 'خصم قيمة سقاية من حساب العامل',
          'created_by': userId,
        });
      } else if (partyType == 'partner') {
        await tx.insert('partner_transactions', {
          'partner_id': partnerId,
          'date': now,
          'type': 'irrigation',
          'amount': totalCharged,
          'ownership_snapshot': null,
          'notes': 'خصم قيمة سقاية من حساب الشريك',
        });
      }
      if (partyType == 'beneficiary' &&
          effectiveType == 'diesel' &&
          calc.dieselLiters > 0) {
        if (shortageLiters > 0) {
          // سلفة تلقائية: تُسجَّل كحركة كمية فقط. قيمتها محتسبة أصلًا ضمن إجمالي
          // السقاية، فلا قيد ولا إضافة للرصيد (منعًا للازدواج وللخصم الوهمي من الصندوق).
          await tx.insert('diesel_movements', {
            'beneficiary_id': beneficiaryId,
            'irrigation_id': id,
            'kind': 'advance',
            'liters': shortageLiters,
            'unit_price': effectiveDieselPrice,
            'amount': AccountingCalculations.roundAmount(
              shortageLiters * effectiveDieselPrice,
              rounding,
            ),
            'date': start.toIso8601String(),
            'created_by': userId,
            'notes': 'سلفة ديزل تلقائية (قيمتها ضمن إجمالي السقاية)',
          });
        }
        await tx.insert('diesel_movements', {
          'beneficiary_id': beneficiaryId,
          'irrigation_id': id,
          'kind': 'consumption',
          'liters': calc.dieselLiters,
          'unit_price': effectiveDieselPrice,
          'amount': calc.dieselAmount,
          'date': start.toIso8601String(),
          'created_by': userId,
          'notes': 'استهلاك جلسة السقي',
        });
      }
      if (paidAmount > 0) {
        final src = await resolvePaymentSource(
          tx,
          paymentMethodId: paymentMethodId,
          cashboxId: cashboxId,
        );
        await _paymentInTx(
          tx,
          beneficiaryId: beneficiaryId,
          amount: paidAmount,
          paymentMethodId: src['method']!,
          cashboxId: src['cashbox']!,
          userId: userId,
          referenceType: 'irrigation',
          referenceId: id,
          referenceNumber: 'IRR-$id',
        );
      }
      if (sessionId != null) {
        // إنهاء الجلسة داخل نفس المعاملة: إن فشل أي جزء تبقى الجلسة «تعمل» ويمكن إعادة المحاولة.
        final st = await tx.rawQuery(_stationDieselStockSql);
        await tx.update(
          'irrigation_sessions',
          {
            'actual_end': endDt.toIso8601String(),
            'timer_stopped_at': endDt.toIso8601String(),
            'status': 'completed',
            'diesel_after': (st.first['stock'] as num?)?.toDouble() ?? 0,
          },
          where: 'id=?',
          whereArgs: [sessionId],
        );
      }
      if (queueId != null) {
        final qt = await tx.rawQuery(
          "SELECT value FROM settings WHERE key='queue_type' LIMIT 1",
        );
        final circular =
            (qt.isEmpty ? 'circular' : '${qt.first['value']}') == 'circular';
        await completeQueueEntryTx(tx, queueId, now, circular: circular);
      }
      if (bookingId != null)
        await tx.update(
          'booking_requests',
          {'status': 'completed', 'reviewed_at': now},
          where: 'id=?',
          whereArgs: [bookingId],
        );
      return id;
    });
  }

  Future<int> _paymentInTx(
    Transaction tx, {
    int? beneficiaryId,
    int? partnerId,
    int? workerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceType,
    int? referenceId,
    String? referenceNumber,
    String? notes,
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    final now = DateTime.now().toIso8601String();
    await _assertPeriodOpen(tx, DateTime.now());
    final id = await tx.insert('payments', {
      'beneficiary_id': beneficiaryId,
      'partner_id': partnerId,
      'worker_id': workerId,
      'amount': amount,
      'date': now,
      'payment_method_id': paymentMethodId,
      'cashbox_id': cashboxId,
      'reference_number': referenceNumber,
      'notes': notes,
      'status': 'posted',
      'created_by': userId,
    });
    // قبض من مستفيد = دخول نقد (+). دفع لعامل/شريك = خروج نقد (−).
    final isOutgoing = beneficiaryId == null;
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance${isOutgoing ? '-' : '+'}? WHERE id=?',
      [amount, cashboxId],
    );
    final method = await tx.query(
      'payment_methods',
      columns: ['ledger_account_code', 'type'],
      where: 'id=?',
      whereArgs: [paymentMethodId],
      limit: 1,
    );
    if (method.isEmpty) throw StateError('طريقة الدفع غير موجودة');
    final ledgerCode =
        (method.first['ledger_account_code'] as String?) ??
        ((method.first['type'] as String?) == 'bank_transfer'
            ? '1100'
            : (method.first['type'] as String?) == 'wallet'
            ? '1120'
            : '1000');
    final cash = await _accountIdTx(tx, ledgerCode);
    final accountCode = beneficiaryId != null
        ? '1200'
        : partnerId != null
        ? '2200'
        : '2100';
    final partyAccount = await _accountIdTx(tx, accountCode);
    await _entry(
      tx,
      description: isOutgoing ? 'دفع لطرف رقم $id' : 'قبض من مستفيد رقم $id',
      referenceType: referenceType ?? 'payment',
      referenceId: referenceId ?? id,
      // قبض: مدين الصندوق / دائن حساب الطرف. دفع: مدين حساب الطرف / دائن الصندوق.
      lines: [
        {
          'account_id': cash,
          'debit': isOutgoing ? 0 : amount,
          'credit': isOutgoing ? amount : 0,
        },
        {
          'account_id': partyAccount,
          'beneficiary_id': beneficiaryId,
          'partner_id': partnerId,
          'worker_id': workerId,
          'debit': isOutgoing ? amount : 0,
          'credit': isOutgoing ? 0 : amount,
        },
      ],
      userId: userId,
    );
    if (beneficiaryId != null) {
      final templates = await tx.query(
        'settings',
        columns: ['key', 'value'],
        where:
            "key IN ('notification_payment_title','notification_payment_body')",
      );
      final map = {
        for (final x in templates) x['key'] as String: x['value'] as String,
      };
      await tx.insert('notifications', {
        'beneficiary_id': beneficiaryId,
        'type': 'payment',
        'title': map['notification_payment_title'] ?? 'تسجيل دفعة',
        'body':
            (map['notification_payment_body'] ??
                    'تم تسجيل دفعة بمبلغ {amount} ريال')
                .replaceAll('{amount}', '$amount'),
        'created_at': now,
      });
    }
    return id;
  }

  Future<int> receivePayment({
    required int beneficiaryId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? referenceNumber,
    String? notes,
  }) => database.transaction(
    (tx) => _paymentInTx(
      tx,
      beneficiaryId: beneficiaryId,
      amount: amount,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      userId: userId,
      referenceNumber: referenceNumber,
      notes: notes,
    ),
  );
  Future<int> payWorker({
    required int workerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? notes,
  }) => database.transaction((tx) async {
    final id = await _paymentInTx(
      tx,
      workerId: workerId,
      amount: amount,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      userId: userId,
      notes: notes,
    );
    await tx.insert('worker_transactions', {
      'worker_id': workerId,
      'date': DateTime.now().toIso8601String(),
      'type': 'payment',
      'amount': amount,
      'cashbox_id': cashboxId,
      'notes': notes,
      'created_by': userId,
    });
    return id;
  });
  Future<int> payPartner({
    required int partnerId,
    required int amount,
    required int paymentMethodId,
    required int cashboxId,
    int? userId,
    String? notes,
  }) => database.transaction((tx) async {
    final id = await _paymentInTx(
      tx,
      partnerId: partnerId,
      amount: amount,
      paymentMethodId: paymentMethodId,
      cashboxId: cashboxId,
      userId: userId,
      notes: notes,
    );
    await tx.insert('partner_transactions', {
      'partner_id': partnerId,
      'date': DateTime.now().toIso8601String(),
      'type': 'payment',
      'amount': amount,
      'notes': notes,
    });
    return id;
  });

  Future<int> addExpense({
    required String category,
    required String title,
    required int amount,
    required DateTime date,
    required int paymentMethodId,
    required int cashboxId,
    int? beneficiaryId,
    int? workerId,
    int? partnerId,
    int? userId,
    String? attachmentPath,
    String? notes,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    if (amount <= 0)
      throw ArgumentError('قيمة المصروف يجب أن تكون أكبر من صفر');
    final id = await tx.insert('expenses', {
      'category': category,
      'title': title,
      'amount': amount,
      'date': date.toIso8601String(),
      'payment_method_id': paymentMethodId,
      'cashbox_id': cashboxId,
      'beneficiary_id': beneficiaryId,
      'worker_id': workerId,
      'partner_id': partnerId,
      'attachment_path': attachmentPath,
      'notes': notes,
      'status': 'posted',
      'created_by': userId,
    });
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
      [amount, cashboxId],
    );
    final exp = await _accountIdTx(tx, _expenseAccount(category));
    final method = await tx.query(
      'payment_methods',
      columns: ['ledger_account_code', 'type'],
      where: 'id=?',
      whereArgs: [paymentMethodId],
      limit: 1,
    );
    if (method.isEmpty) throw StateError('طريقة الدفع غير موجودة');
    final ledgerCode =
        (method.first['ledger_account_code'] as String?) ??
        ((method.first['type'] as String?) == 'bank_transfer'
            ? '1100'
            : (method.first['type'] as String?) == 'wallet'
            ? '1120'
            : '1000');
    final cash = await _accountIdTx(tx, ledgerCode);
    await _entry(
      tx,
      description: title,
      referenceType: 'expense',
      referenceId: id,
      lines: [
        {'account_id': exp, 'debit': amount, 'credit': 0},
        {'account_id': cash, 'debit': 0, 'credit': amount},
      ],
      userId: userId,
      date: date,
    );
    return id;
  });

  String _expenseAccount(String category) => switch (category) {
    'workers' => '5000',
    'partners' => '5000',
    'fuel' || 'diesel' => '5010',
    'oil' || 'grease' => '5020',
    'maintenance' || 'parts' => '5030',
    _ => '5030',
  };

  Future<void> cancelExpense(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب الإلغاء مطلوب');
    await database.transaction((tx) async {
      final r = await tx.query(
        'expenses',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (r.isEmpty || r.first['status'] != 'posted')
        throw StateError('المصروف غير قابل للإلغاء');
      await _assertPeriodOpen(tx, DateTime.now());
      await tx.update(
        'expenses',
        {
          'status': 'cancelled',
          'notes': '${r.first['notes'] ?? ''}\nإلغاء: $reason',
        },
        where: 'id=?',
        whereArgs: [id],
      );
      // إعادة المبلغ إلى الصندوق + قيد عكسي (بدل ترك الأستاذ والصندوق على حالهما).
      final cb = r.first['cashbox_id'] as int?;
      if (cb != null)
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
          [(r.first['amount'] as num).round(), cb],
        );
      await _reverseEntriesTx(
        tx,
        referenceType: 'expense',
        referenceId: id,
        reason: reason,
        userId: userId,
      );
      // داخل المعاملة: يجب استعمال auditTx لا audit (الأخيرة تستعمل الاتصال الخارجي).
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'expenses',
        recordId: id,
        oldValues: r.first,
        reason: reason,
      );
    });
  }

  Future<void> addDieselMovement({
    int? beneficiaryId,
    int? irrigationId,
    required String kind,
    required double liters,
    required int unitPrice,
    required DateTime date,
    int? cashboxId,
    int? userId,
    String? notes,
  }) async {
    if (liters <= 0) throw ArgumentError('كمية الديزل يجب أن تكون أكبر من صفر');
    // قراءة الإعدادات خارج المعاملة لتفادي تعليق sqflite (استعلام على الاتصال أثناء معاملة مفتوحة).
    final financialCredit = await _settingBool(
      'diesel_delivery_financial_credit',
    );
    await database.transaction((tx) async {
      await _assertPeriodOpen(tx, date);
      final amount = (liters * unitPrice).round();
      final stock = await tx.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
      );
      final current = (stock.first['stock'] as num?)?.toDouble() ?? 0;
      if ((kind == 'delivery' || kind == 'consumption') && liters > current)
        throw StateError('كمية الديزل المطلوبة أكبر من المخزون المتاح');
      final id = await tx.insert('diesel_movements', {
        'beneficiary_id': beneficiaryId,
        'irrigation_id': irrigationId,
        'cashbox_id': cashboxId,
        'kind': kind,
        'liters': liters,
        'unit_price': unitPrice,
        'amount': amount,
        'date': date.toIso8601String(),
        'notes': notes,
        'created_by': userId,
      });
      if (kind == 'receipt' && cashboxId != null) {
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
          [amount, cashboxId],
        );
        final inventory = await _accountIdTx(tx, '1300');
        final method = await tx.query(
          'payment_methods',
          columns: ['ledger_account_code'],
          where: 'id=?',
          whereArgs: [1],
          limit: 1,
        );
        final cash = await _accountIdTx(
          tx,
          (method.first['ledger_account_code'] as String?) ?? '1000',
        );
        await _entry(
          tx,
          description: 'شراء/إضافة ديزل للمخزون',
          referenceType: 'diesel_receipt',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {'account_id': cash, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'consumption') {
        final fuelExpense = await _accountIdTx(tx, '5010');
        final inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'استهلاك ديزل',
          referenceType: 'diesel_consumption',
          referenceId: id,
          lines: [
            {'account_id': fuelExpense, 'debit': amount, 'credit': 0},
            {'account_id': inventory, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'delivery' && beneficiaryId != null && financialCredit) {
        // تسليم الديزل رصيد مالي «له»: مدين مخزون الديزل / دائن ذمة المستفيد
        // (نفس اتجاه كشف الحساب الذي يطرحه من الرصيد).
        final rec = await _accountIdTx(tx, '1200'),
            inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'تسليم ديزل من المستفيد (رصيد مالي)',
          referenceType: 'diesel',
          referenceId: id,
          lines: [
            {'account_id': inventory, 'debit': amount, 'credit': 0},
            {
              'account_id': rec,
              'beneficiary_id': beneficiaryId,
              'debit': 0,
              'credit': amount,
            },
          ],
          userId: userId,
          date: date,
        );
      }
      if (kind == 'advance' && beneficiaryId != null) {
        // سلفة ديزل عينية: لا خروج نقد، بل خروج من مخزون الديزل.
        final rec = await _accountIdTx(tx, '1200'),
            inventory = await _accountIdTx(tx, '1300');
        await _entry(
          tx,
          description: 'سلفة ديزل للمستفيد',
          referenceType: 'diesel_advance',
          referenceId: id,
          lines: [
            {
              'account_id': rec,
              'beneficiary_id': beneficiaryId,
              'debit': amount,
              'credit': 0,
            },
            {'account_id': inventory, 'debit': 0, 'credit': amount},
          ],
          userId: userId,
          date: date,
        );
      }
    });
  }

  Future<double> dieselStock() async {
    final r = await database.query(
      "SELECT COALESCE(SUM(CASE WHEN kind IN ('receipt','opening_balance','correction') THEN liters WHEN kind IN ('delivery','consumption') THEN -liters ELSE 0 END),0) stock FROM diesel_movements",
    );
    return (r.first['stock'] as num?)?.toDouble() ?? 0;
  }

  /// كود حساب الأستاذ الذي يمثل الصندوق (من طريقة الدفع المرتبطة به).
  Future<String> _cashboxAccountCode(Transaction tx, int cashboxId) async {
    final m = await tx.query(
      'payment_methods',
      columns: ['ledger_account_code', 'type'],
      where: 'cashbox_id=? AND active=1',
      whereArgs: [cashboxId],
      orderBy: 'id',
      limit: 1,
    );
    if (m.isEmpty) return '1000';
    final code = m.first['ledger_account_code'] as String?;
    if (code != null && code.isNotEmpty) return code;
    return switch (m.first['type'] as String?) {
      'bank_transfer' => '1100',
      'wallet' => '1120',
      _ => '1000',
    };
  }

  Future<void> transferCash({
    required int from,
    required int to,
    required int amount,
    required DateTime date,
    int? userId,
    bool opening = false,
    String? reference,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    if (amount <= 0)
      throw ArgumentError('قيمة التحويل يجب أن تكون أكبر من صفر');
    if (from == to) throw ArgumentError('لا يمكن التحويل إلى نفس الصندوق');
    if (!opening) {
      final r = await tx.query(
        'cashboxes',
        columns: ['current_balance'],
        where: 'id=?',
        whereArgs: [from],
        limit: 1,
      );
      if (r.isEmpty) throw StateError('صندوق المصدر غير موجود');
      final balance = (r.first['current_balance'] as num?)?.round() ?? 0;
      if (balance < amount) throw StateError('الرصيد غير كافٍ للتحويل');
    }
    final id = await tx.insert('cashbox_transfers', {
      'from_cashbox_id': from,
      'to_cashbox_id': to,
      'amount': amount,
      'date': date.toIso8601String(),
      'is_opening_transfer': opening ? 1 : 0,
      'reference': reference,
      'created_by': userId,
    });
    if (!opening)
      await tx.rawUpdate(
        'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
        [amount, from],
      );
    await tx.rawUpdate(
      'UPDATE cashboxes SET current_balance=current_balance+? WHERE id=?',
      [amount, to],
    );
    // حساب كل صندوق يُشتق من طريقة الدفع المرتبطة به (ledger_account_code أو نوعها).
    final toAccount = await _accountIdTx(tx, await _cashboxAccountCode(tx, to));
    // التحويل الافتتاحي: يقابله حساب الأرصدة الافتتاحية (3000) لا صندوق آخر،
    // لأن رصيد المصدر لا ينقص فيه.
    final fromAccount = opening
        ? await _accountIdTx(tx, '3000')
        : await _accountIdTx(tx, await _cashboxAccountCode(tx, from));
    await _entry(
      tx,
      description: opening ? 'تحويل افتتاحي' : 'تحويل بين الصناديق',
      referenceType: 'cashbox_transfer',
      referenceId: id,
      lines: [
        {'account_id': toAccount, 'debit': amount, 'credit': 0},
        {'account_id': fromAccount, 'debit': 0, 'credit': amount},
      ],
      userId: userId,
      date: date,
    );
  });

  Future<void> createWorkerAccrual({
    required int workerId,
    required int amount,
    required DateTime date,
    double hours = 0,
    int rateSnapshot = 0,
    double percentageSnapshot = 0,
    int? userId,
    String? memo,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    final id = await tx.insert('worker_transactions', {
      'worker_id': workerId,
      'date': date.toIso8601String(),
      'type': 'accrual',
      'hours': hours,
      'rate_snapshot': rateSnapshot,
      'percentage_snapshot': percentageSnapshot,
      'amount': amount,
      'notes': memo,
      'created_by': userId,
    });
    final exp = await _accountIdTx(tx, '5000'),
        payable = await _accountIdTx(tx, '2100');
    await _entry(
      tx,
      description: 'استحقاق عامل',
      referenceType: 'worker',
      referenceId: id,
      lines: [
        {
          'account_id': exp,
          'worker_id': workerId,
          'debit': amount,
          'credit': 0,
        },
        {
          'account_id': payable,
          'worker_id': workerId,
          'debit': 0,
          'credit': amount,
        },
      ],
      userId: userId,
      date: date,
    );
  });

  Future<void> createPartnerShare({
    required int partnerId,
    required int amount,
    required DateTime date,
    double? percentage,
    int? userId,
  }) async => database.transaction((tx) async {
    await _assertPeriodOpen(tx, date);
    final id = await tx.insert('partner_transactions', {
      'partner_id': partnerId,
      'date': date.toIso8601String(),
      'type': 'share_accrual',
      'amount': amount,
      'ownership_snapshot': percentage,
    });
    final expense = await _accountIdTx(tx, '5000'),
        payable = await _accountIdTx(tx, '2200');
    await _entry(
      tx,
      description: 'حصة شريك من النشاط',
      referenceType: 'partner',
      referenceId: id,
      lines: [
        {
          'account_id': expense,
          'partner_id': partnerId,
          'debit': amount,
          'credit': 0,
        },
        {
          'account_id': payable,
          'partner_id': partnerId,
          'debit': 0,
          'credit': amount,
        },
      ],
      userId: userId,
      date: date,
    );
  });

  Future<Map<String, int>> beneficiaryBalance(int id) async {
    final set = await settings();
    final includeDiesel = set['diesel_delivery_financial_credit'] == 'true';
    final r = await database.query(
      '''SELECT b.opening_balance opening,b.carried_balance carried,
      COALESCE((SELECT SUM(total_amount) FROM irrigations WHERE beneficiary_id=b.id AND status!='cancelled'),0) irrigation,
      COALESCE((SELECT SUM(amount) FROM diesel_movements WHERE beneficiary_id=b.id AND kind='advance' AND irrigation_id IS NULL),0) advances,
      COALESCE((SELECT SUM(amount) FROM payments WHERE beneficiary_id=b.id AND status='posted'),0) paid,
      COALESCE((SELECT SUM(amount) FROM diesel_movements WHERE beneficiary_id=b.id AND kind='delivery'),0) diesel_credit
      FROM beneficiaries b WHERE b.id=?''',
      args: [id],
    );
    final x = r.first;
    final balance = AccountingCalculations.beneficiaryBalance(
      opening: (x['opening'] as num?)?.round() ?? 0,
      carried: (x['carried'] as num?)?.round() ?? 0,
      irrigationDue: (x['irrigation'] as num?)?.round() ?? 0,
      advances: (x['advances'] as num?)?.round() ?? 0,
      paid: (x['paid'] as num?)?.round() ?? 0,
      financialDieselCredit: includeDiesel
          ? (x['diesel_credit'] as num?)?.round() ?? 0
          : 0,
    );
    return {
      'balance': balance,
      'due': balance > 0 ? balance : 0,
      'credit': balance < 0 ? -balance : 0,
    };
  }

  Future<Map<String, int>> workerBalance(int id) async {
    final r = await database.query(
      "SELECT COALESCE((SELECT opening_balance+carried_balance FROM workers WHERE id=?),0)+COALESCE(SUM(CASE WHEN type IN ('accrual', 'salary', 'irrigation_reversal') THEN amount ELSE -amount END),0) balance FROM worker_transactions WHERE worker_id=?",
      args: [id, id],
    );
    final v = (r.first['balance'] as num?)?.round() ?? 0;
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
  }

  Future<Map<String, int>> partnerBalance(int id) async {
    final r = await database.query(
      "SELECT COALESCE((SELECT opening_balance+carried_balance FROM partners WHERE id=?),0)+COALESCE(SUM(CASE WHEN type IN ('share_accrual', 'contribution') THEN amount ELSE -amount END),0) balance FROM partner_transactions WHERE partner_id=?",
      args: [id, id],
    );
    final v = (r.first['balance'] as num?)?.round() ?? 0;
    return {'balance': v, 'due': v > 0 ? v : 0, 'credit': v < 0 ? -v : 0};
  }

  Future<void> cancelIrrigation(int id, int userId, String reason) async {
    if (reason.trim().isEmpty) throw ArgumentError('سبب إلغاء السقاية مطلوب');
    await database.transaction((tx) async {
      final rows = await tx.query(
        'irrigations',
        where: 'id=?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty || rows.first['status'] == 'cancelled')
        throw StateError('السقاية غير موجودة أو ملغاة مسبقًا');
      final old = rows.first;
      await _assertPeriodOpen(tx, DateTime.now());
      await tx.update(
        'irrigations',
        {
          'status': 'cancelled',
          'notes': '${old['notes'] ?? ''}\nإلغاء: $reason',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id=?',
        whereArgs: [id],
      );
      // 1) عكس الدفعة المرتبطة (إن وُجدت) وإعادة رصيد الصندوق
      final pays = await tx.query(
        'payments',
        where: "reference_number=? AND status='posted'",
        whereArgs: ['IRR-$id'],
      );
      for (final pay in pays) {
        await tx.update(
          'payments',
          {'status': 'cancelled'},
          where: 'id=?',
          whereArgs: [pay['id']],
        );
        await tx.rawUpdate(
          'UPDATE cashboxes SET current_balance=current_balance-? WHERE id=?',
          [(pay['amount'] as num).round(), pay['cashbox_id']],
        );
      }
      // 2) قيود عكسية لكل قيود السقاية (الاستحقاق + الدفعة)
      await _reverseEntriesTx(
        tx,
        referenceType: 'irrigation',
        referenceId: id,
        reason: reason,
        userId: userId,
      );
      // 3) حركات الديزل المرتبطة: تُحذف وتُحفظ قيمها في سجل التدقيق
      final moves = await tx.query(
        'diesel_movements',
        where: 'irrigation_id=?',
        whereArgs: [id],
      );
      if (moves.isNotEmpty) {
        await tx.delete(
          'diesel_movements',
          where: 'irrigation_id=?',
          whereArgs: [id],
        );
        await database.auditTx(
          tx,
          userId: userId,
          operation: 'delete',
          table: 'diesel_movements',
          recordId: id,
          oldValues: moves,
          reason: 'إلغاء السقاية: $reason',
        );
      }
      // 4) حساب العامل/الشريك
      // عكس بحركة مقابلة (لا حذف) ليبقى أثر الحركة الأصلية في كشف العامل.
      if (old['party_type'] == 'worker' && old['worker_id'] != null) {
        await tx.insert('worker_transactions', {
          'worker_id': old['worker_id'],
          'date': DateTime.now().toIso8601String(),
          'type': 'irrigation_reversal',
          'amount': (old['total_amount'] as num).round(),
          'reference_type': 'irrigation_cancel',
          'reference_id': id,
          'notes': 'عكس سقاية رقم $id: $reason',
          'created_by': userId,
        });
      }
      if (old['party_type'] == 'partner' && old['partner_id'] != null) {
        await tx.insert('partner_transactions', {
          'partner_id': old['partner_id'],
          'date': DateTime.now().toIso8601String(),
          'type': 'contribution',
          'amount': (old['total_amount'] as num).round(),
          'notes': 'عكس سقاية رقم $id: $reason',
        });
      }
      await database.auditTx(
        tx,
        userId: userId,
        operation: 'cancel',
        table: 'irrigations',
        recordId: id,
        oldValues: old,
        reason: reason,
      );
    });
  }

  /// جداول النسخة المحمولة (JSON) مرتّبة بحيث تسبق الجداولُ الأمُّ جداولَها التابعة
  /// (تُدرج بهذا الترتيب وتُحذف بعكسه، فلا تنتهك المفاتيح الأجنبية).
  static const List<String> portableTables = [
    'stations',
    'pumps',
    'beneficiaries',
    'partners',
    'workers',
    'queue_entries',
    'booking_requests',
    'irrigation_sessions',
    'irrigations',
    'cloud_periods',
    'diesel_movements',
    'payment_methods',
    'cashboxes',
    'cashbox_transfers',
    'payments',
    'expenses',
    'worker_transactions',
    'partner_transactions',
    'accounts',
    'journal_entries',
    'journal_lines',
    'audit_logs',
    'settings',
    'notifications',
    'backup_records',
    'sync_queue',
    'app_users',
    'period_closures',
    'beneficiary_auth_codes',
    'beneficiary_sessions',
    'notification_templates',
  ];

  /// جداول أُضيفت للنسخة لاحقًا؛ قد لا توجد في ملفات JSON القديمة.
  static const List<String> optionalPortableTables = [
    'cloud_periods',
    'period_closures',
    'beneficiary_auth_codes',
    'beneficiary_sessions',
    'notification_templates',
  ];

  Future<String> exportStateJson() async {
    final d = await database.db;
    final out = <String, dynamic>{
      '_meta': {
        'format_version': 2,
        'exported_at': DateTime.now().toIso8601String(),
      },
    };
    for (final t in portableTables) {
      out[t] = await d.query(t);
    }
    return jsonEncode(out);
  }
}
