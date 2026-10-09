from pathlib import Path
import re, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
app=(ROOT/'lib/features/app.dart').read_text(); repo=(ROOT/'lib/data/repositories/repositories.dart').read_text(); acct=(ROOT/'lib/domain/accounting/accounting_service.dart').read_text(); pdf=(ROOT/'lib/services/report_service.dart').read_text(); backup=(ROOT/'lib/services/backup_service.dart').read_text()
checks=[]
def check(name,ok,detail=''): checks.append((name,bool(ok),detail))
check('system type has one repository authority','Future<Map<String, Object?>> systemConfiguration()' in repo and 'Future<void> setSystemType(String type)' in repo)
check('changing system type synchronizes selected pump',"'system_type'" in repo[repo.index('Future<void> setSystemType'):] and "'pumps'," in repo[repo.index('Future<void> setSystemType'):repo.index('Future<void> setSetting')])
check('operation ignores UI system type and uses effective settings type',"final effectiveType = set['system_type'] ?? 'diesel';" in acct and "'system_type': effectiveType" in acct)
check('operation enforces selected pump','configuredPumpId' in acct and 'pumpId != configuredPumpId' in acct)
check('new irrigation reads type from settings',"type = st['system_type'] ?? 'diesel';" in app and "type = '${selected['system_type']}';" not in app)
check('dashboard derives type from central configuration','SystemConfig.load(widget.r)' in app and "SELECT (SELECT value FROM settings WHERE key='system_type'" in repo)
check('solar removes diesel menu entry',"if (systemType == 'solar') s.remove(6);" in app)
check('dashboard diesel card is conditional',"if (systemType == 'diesel')" in app and "'رصيد الديزل'" in app)
check('new irrigation diesel balance is conditional',"partyType == 'beneficiary' && type == 'diesel'" in app)
check('settings diesel pricing is conditional',"(s['system_type'] ?? 'diesel') == 'diesel'" in app)
check('settings diesel warning is conditional',"setTile('diesel_warning_percent'" in app and "== 'diesel'" in app)
check('diesel page refuses solar',"if (!cfg.isDiesel)" in app and "عناصر الديزل غير متاحة" in app)
check('reports hide diesel inventory on solar',"currentType == 'solar' && k == 'diesel_inventory'" in app)
check('diesel inventory report blocked at data layer',"key == 'diesel_inventory' && currentSystemType != 'diesel'" in repo)
check('diesel stock not read by solar session start',"set['system_type'] == 'diesel' ? await accounting.dieselStock()" in repo)
check('PDF embeds both Arabic fonts',"assets/fonts/NotoNaskhArabic-Regular.ttf" in pdf and "assets/fonts/NotoNaskhArabic-Bold.ttf" in pdf)
check('PDF table cells explicitly use Arabic font','cellStyle: pw.TextStyle(font: font' in pdf)
check('PDF filter/footer use Arabic font','pw.Text(filterText, style: pw.TextStyle(font: font' in pdf and "'صفحة ${pi + 1} / ${pages.length}'" in pdf)
check('reports have explicit per-report columns','static const reportColumns' in pdf and 'cash_flow' in pdf)
check('PDF uses landscape for wide tables','PdfPageFormat.a4.landscape' in pdf)
check('system enum never emitted raw',"'system_type'" in pdf and "_ => 'غير محدد'" in pdf)
backup_create=backup[backup.index('Future<File> createDatabaseBackup'):backup.index('Future<String?> saveBackupToLocation')]
backup_restore=backup[backup.index('Future<Map<String, dynamic>> pickAndRestoreDatabase'):backup.index('Future<List<Map<String, Object?>>> history')]
check('backup checkpoints/closes before copy','wal_checkpoint(TRUNCATE)' in backup_create and 'await accounting.database.close();' in backup_create)
check('backup validates copied file before logging','validateDatabaseFile(target.path)' in backup_create)
check('backup reopens DB before history','await accounting.database.db;' in backup_create and backup_create.index('await accounting.database.db;') < backup_create.index("'backup_records'"))
check('restore validates source before replacement','validateDatabaseFile(source)' in backup_restore)
check('restore reopens installed database','await File(source).copy(dbPath)' in backup_restore and 'await accounting.database.db;' in backup_restore and 'validateDatabaseFile(dbPath)' in backup_restore)
check('restore has rollback copy','rollback' in backup_restore and 'await rollback.copy(dbPath)' in backup_restore and 'await accounting.database.db;' in backup_restore[backup_restore.index('catch'):])
failed=[x for x in checks if not x[1]]
for name,ok,detail in checks: print(('PASS' if ok else 'FAIL'),'-',name)
print(f'\nFOUR-LAYER ACCEPTANCE: {len(checks)-len(failed)}/{len(checks)} passed')
if failed: sys.exit(1)
