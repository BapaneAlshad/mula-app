import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

/// The single local source of truth. The injectable factory supports SQLite
/// integration tests without an Android device.
class AppDatabase {
  AppDatabase({
    DatabaseFactory? factory,
    String? databasePath,
    bool singleInstance = true,
  })
      : _factory = factory ?? databaseFactory,
        _databasePath = databasePath,
        _singleInstance = singleInstance;

  final DatabaseFactory _factory;
  final String? _databasePath;
  final bool _singleInstance;
  Future<Database>? _opening;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final databasePath = _databasePath ??
        path.join(await _factory.getDatabasesPath(), 'mula.db');
    return _factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: _singleInstance,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await database.execute('PRAGMA busy_timeout = 5000');
        },
        onCreate: (database, version) async {
          for (final statement in _schema) {
            await database.execute(statement);
          }
        },
      ),
    );
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }

  static const _schema = <String>[
    '''CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL DEFAULT 'Anggit',
      wakeTime TEXT NOT NULL DEFAULT '04:30',
      sleepTime TEXT NOT NULL DEFAULT '22:00',
      workStartTime TEXT NOT NULL DEFAULT '08:00',
      workEndTime TEXT NOT NULL DEFAULT '16:00',
      strictnessLevel TEXT NOT NULL DEFAULT 'Seimbang'
        CHECK (strictnessLevel IN ('Lembut','Seimbang','Tegas')),
      onboardingCompleted INTEGER NOT NULL DEFAULT 0
        CHECK (onboardingCompleted IN (0,1)),
      createdAt TEXT NOT NULL
    )''',
    '''CREATE TABLE schedule_templates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      startTime TEXT NOT NULL,
      endTime TEXT NOT NULL,
      category TEXT NOT NULL CHECK (category IN
        ('Wajib','Penting','Jika Sempat','Rutinitas','Tim','Pribadi','Side Job')),
      daysOfWeek TEXT NOT NULL DEFAULT '[1,2,3,4,5,6,7]',
      isActive INTEGER NOT NULL DEFAULT 1 CHECK (isActive IN (0,1)),
      sortOrder INTEGER NOT NULL DEFAULT 0,
      checklistJson TEXT NOT NULL DEFAULT '[]',
      UNIQUE(userId, sortOrder)
    )''',
    '''CREATE TABLE daily_tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      date TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      category TEXT NOT NULL CHECK (category IN
        ('Wajib','Penting','Jika Sempat','Rutinitas','Tim','Pribadi','Side Job')),
      priority TEXT NOT NULL DEFAULT 'Reguler'
        CHECK (priority IN ('Top 1','Top 2','Top 3','Reguler')),
      estimatedMinutes INTEGER NOT NULL DEFAULT 25 CHECK (estimatedMinutes > 0),
      energyLevel TEXT NOT NULL DEFAULT 'Sedang'
        CHECK (energyLevel IN ('Rendah','Sedang','Tinggi')),
      status TEXT NOT NULL DEFAULT 'Belum mulai' CHECK (status IN
        ('Belum mulai','Sedang berjalan','Selesai','Dilewati','Ditunda')),
      points INTEGER NOT NULL DEFAULT 0 CHECK (points >= 0),
      sourceScheduleId INTEGER REFERENCES schedule_templates(id) ON DELETE SET NULL,
      completedAt TEXT,
      skippedReason TEXT,
      outputNote TEXT NOT NULL DEFAULT '',
      subtasksJson TEXT NOT NULL DEFAULT '[]',
      UNIQUE(userId, date, sourceScheduleId)
    )''',
    '''CREATE TABLE focus_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      taskId INTEGER REFERENCES daily_tasks(id) ON DELETE SET NULL,
      mode TEXT NOT NULL,
      plannedSeconds INTEGER NOT NULL CHECK (plannedSeconds > 0),
      actualSeconds INTEGER NOT NULL DEFAULT 0 CHECK (actualSeconds >= 0),
      pauseCount INTEGER NOT NULL DEFAULT 0 CHECK (pauseCount >= 0),
      status TEXT NOT NULL DEFAULT 'Berjalan'
        CHECK (status IN ('Berjalan','Selesai','Dibatalkan')),
      cancelReason TEXT,
      startedAt TEXT NOT NULL,
      completedAt TEXT
    )''',
    '''CREATE UNIQUE INDEX one_active_focus_per_user
      ON focus_sessions(userId) WHERE status = 'Berjalan' ''',
    '''CREATE TABLE thought_parkings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      content TEXT NOT NULL,
      type TEXT NOT NULL CHECK (type IN ('Kekhawatiran','Ide','Masalah','Tugas','Emosi')),
      intensity INTEGER NOT NULL CHECK (intensity BETWEEN 1 AND 10),
      needsAction INTEGER NOT NULL DEFAULT 0 CHECK (needsAction IN (0,1)),
      nextAction TEXT NOT NULL DEFAULT '',
      reviewAt TEXT,
      status TEXT NOT NULL DEFAULT 'Terparkir'
        CHECK (status IN ('Terparkir','Ditinjau','Selesai')),
      createdAt TEXT NOT NULL
    )''',
    '''CREATE TABLE anxiety_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      mode TEXT NOT NULL,
      durationSeconds INTEGER NOT NULL CHECK (durationSeconds >= 0),
      anxietyBefore INTEGER NOT NULL CHECK (anxietyBefore BETWEEN 1 AND 10),
      anxietyAfter INTEGER NOT NULL CHECK (anxietyAfter BETWEEN 1 AND 10),
      completedAt TEXT NOT NULL
    )''',
    '''CREATE TABLE daily_scores (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      userId INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      date TEXT NOT NULL,
      morningScore INTEGER NOT NULL DEFAULT 0 CHECK (morningScore BETWEEN 0 AND 20),
      workScore INTEGER NOT NULL DEFAULT 0 CHECK (workScore BETWEEN 0 AND 35),
      healthFamilyScore INTEGER NOT NULL DEFAULT 0 CHECK (healthFamilyScore BETWEEN 0 AND 25),
      sideJobScore INTEGER NOT NULL DEFAULT 0 CHECK (sideJobScore BETWEEN 0 AND 20),
      totalScore INTEGER NOT NULL DEFAULT 0 CHECK (totalScore BETWEEN 0 AND 100),
      moodScore INTEGER NOT NULL DEFAULT 5 CHECK (moodScore BETWEEN 1 AND 10),
      anxietyScore INTEGER NOT NULL DEFAULT 5 CHECK (anxietyScore BETWEEN 1 AND 10),
      dayMode TEXT NOT NULL DEFAULT 'Normal'
        CHECK (dayMode IN ('Normal','Minimum','Adaptasi','Reset24Jam')),
      adaptationReason TEXT NOT NULL DEFAULT '',
      valorantUsed INTEGER NOT NULL DEFAULT 0 CHECK (valorantUsed IN (0,1)),
      valorantPenaltyNextDay INTEGER NOT NULL DEFAULT 0
        CHECK (valorantPenaltyNextDay IN (0,1)),
      completedSummary TEXT NOT NULL DEFAULT '',
      mainObstacle TEXT NOT NULL DEFAULT '',
      gratitudeNote TEXT NOT NULL DEFAULT '',
      firstStepTomorrow TEXT NOT NULL DEFAULT '',
      notes TEXT NOT NULL DEFAULT '',
      UNIQUE(userId, date),
      CHECK (totalScore = morningScore + workScore + healthFamilyScore + sideJobScore)
    )''',
    '''CREATE TABLE app_preferences (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )''',
    'CREATE INDEX tasks_user_date ON daily_tasks(userId, date)',
    'CREATE INDEX focus_user_start ON focus_sessions(userId, startedAt)',
    'CREATE INDEX thoughts_user_status ON thought_parkings(userId, status)',
  ];
}
