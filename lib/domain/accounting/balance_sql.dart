/// المصدر الوحيد لصيغة رصيد المستفيد بصيغة SQL.
///
/// الرصيد = الافتتاحي + المرحّل + السقايات غير الملغاة + سلف الديزل اليدوية
///          − الدفعات المرحَّلة − تسليم الديزل (فقط إن كان رصيدًا ماليًا).
///
/// كانت الصيغة منسوخة في ست مواضع (قائمة المستفيدين، ملخص الطرف، تقارير المديونيات
/// والمحتاجين، لوحة التحكم، ورصيد المستفيد في الخدمة)؛ أي تعديل عليها يجب أن يتم هنا فقط.
/// (خادم server.dart حزمة منفصلة ولا يستطيع استيراد هذا الملف، وله نسخته الخاصة).
class BalanceSql {
  BalanceSql._();

  /// تعبير SQL (بلا اسم عمود) يحسب رصيد المستفيد الذي اسمه المستعار [alias].
  /// موجب = عليه، سالب = له.
  static String beneficiary([String alias = 'b']) {
    final a = alias;
    return "$a.opening_balance+$a.carried_balance"
        "+COALESCE((SELECT SUM(i.total_amount) FROM irrigations i WHERE i.beneficiary_id=$a.id AND i.status!='cancelled'),0)"
        "+COALESCE((SELECT SUM(d.amount) FROM diesel_movements d WHERE d.beneficiary_id=$a.id AND d.kind='advance' AND d.irrigation_id IS NULL),0)"
        "-COALESCE((SELECT SUM(p.amount) FROM payments p WHERE p.beneficiary_id=$a.id AND p.status='posted'),0)"
        "-CASE WHEN (SELECT value FROM settings WHERE key='diesel_delivery_financial_credit')='true' "
        "THEN COALESCE((SELECT SUM(d2.amount) FROM diesel_movements d2 WHERE d2.beneficiary_id=$a.id AND d2.kind='delivery'),0) ELSE 0 END";
  }

  /// أنواع حركات العامل التي تزيد المستحق له (الباقي ينقصه: دفع، سقاية خُصمت منه...).
  static const String workerCredit =
      "('accrual','salary','irrigation_reversal','payment_reversal')";

  /// أنواع حركات الشريك التي تزيد المستحق له. «irrigation_reversal» و«payment_reversal»
  /// عكسٌ لخصم سابق فتزيد الرصيد لكنها ليست أرباحًا ولا مساهمة.
  static const String partnerCredit =
      "('share_accrual','contribution','irrigation_reversal','payment_reversal')";

  /// الأنواع التي تُعدّ «أرباح/مستحقات مكتسبة» للشريك (بدون عكوس).
  static const String partnerEarnings = "('share_accrual','contribution')";
}
