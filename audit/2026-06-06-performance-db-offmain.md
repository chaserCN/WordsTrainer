# Аудит: вынос запросов БД с главного потока

**Дата аудита:** 2026-06-06
**Диапазон:** `65acd63..HEAD` (perf-работа за последние ~2 часа)

> **⚠️ Статус перепроверки (2026-06-06, после коммита `7146696`):**
> Параллельная сессия исправила обе 🔴 HIGH-находки и обе ключевые 🟡 MEDIUM уже после
> первой версии этого аудита. Актуальный статус каждой находки помечен ниже
> (✅ FIXED / ⚠️ OPEN). Сводка — в конце документа.

## Коммиты в обзоре
| hash | сообщение |
|------|-----------|
| `7d3a8c8` | Support incremental bootstrap progress |
| `00abd1a` | Coalesce dashboard reloads |
| `4a2bf52` | Load statistics snapshot off main actor |
| `0c3033a` | Load today dashboard snapshot off main actor |
| `29ce164` | Cache word search fuzzy candidates |
| `aa9312a` | Stabilize database setup and sync revision tracking |
| `529d662` | Prime today exercise modes from dashboard snapshot |
| `7146696` | Use WAL read-only snapshots for dashboard data *(фикс находок аудита)* |

---

## Архитектура — верная ✅

`DeckStore.todayDashboardSnapshot(userID:)` / `statisticsSnapshot(userID:)`
(`Words Trainer/Services/DeckStore.swift:121`) запускают `Task.detached(.userInitiated)`,
который открывает **собственный `ContentDatabase`**, выполняет чтения на фоновом потоке и
возвращает `Sendable`-снапшот (`DeckTodaySnapshot` / `DeckStatisticsSnapshot`). Главное
соединение между потоками не шарится — корректный способ избежать гонок на SQLite-указателе.

Реактивная обвязка: дебаунс перезагрузок (250 мс + generation), гейтинг по `isVisible`,
прокидывание `initial*` в модалку, статический `monthFormatter`.

---

## Находки

### ✅ FIXED · 🔴 HIGH — WAL не включён, а соединений теперь несколько
**Было:** `sqlite3_open` (rollback-journal) + только `busy_timeout(5s)`; несколько соединений
(main + фоновые снапшоты + синк) блокировали друг друга, читатель мог зависнуть до 5 с и упасть
с `SQLITE_BUSY`.
**Стало (`7146696`):** `ContentDatabase.swift:97` — `sqlite3_open_v2` с флагами;
`PRAGMA journal_mode = WAL` (строка 131), `synchronous = NORMAL` (117). WAL включается один раз
при подготовке схемы.

### ✅ FIXED · 🔴 HIGH — 37 UPDATE-сканов + FS-нормализация на каждом открытии
**Было:** `executeMigrations()` + `normalizeUUIDColumns()` (37 `UPDATE … GLOB`) +
`normalizeDeckMediaFolders()` на **каждый** `init`, под глобальным локом, способным застопорить
главный поток.
**Стало (`7146696`):** появился `OpenMode { readWrite, readOnly }`
(`ContentDatabase.swift:77`). Подготовка схемы вынесена в `prepareSchemaIfNeeded(path:)`
(строка 127), которая выполняется **один раз на путь за процесс** (гейт по
`contentDatabaseSetupPaths`, строка 130) и **только для `readWrite`** (строка 102). Снапшоты
открываются `mode: .readOnly` (`SQLITE_OPEN_READONLY` + `PRAGMA query_only = ON`), поэтому
нормализацию/миграции не трогают и не пишут.

### ✅ FIXED · 🟡 MEDIUM — снапшот без read-транзакции
**Стало (`7146696`):** добавлен `readTransaction { … }` (`BEGIN DEFERRED`,
`ContentDatabase.swift:140`); оба загрузчика оборачивают чтения в него
(`DeckStore.swift:491`, `DeckStore.swift:535`) → консистентный снимок без блокировки писателя
в WAL.

### ✅ FIXED · 🟡 MEDIUM — синхронный запрос к БД на главном потоке
**Было:** `TodayAllDecksModesView.reloadPracticeCount()` синхронно звал
`store.todayPracticeCardCount()` / `store.todayStudyCards()` на main-акторе.
**Стало:** теперь через `await DeckStore.todayDashboardSnapshot(...)`
(`DashboardViews.swift:1632`, `:1678`) — read-only снапшот в фоне.

### ⚠️ OPEN · 🟡 MEDIUM — перекрывающиеся reload не взаимоисключаются
`scheduleLocalDataReload` (`DashboardViews.swift`): generation-гард защищает только
присваивание `reloadTask = nil`, но не сами записи в `@State`. Пока `await reload()` в полёте,
новая нотификация запускает ещё один `reload()`; внутренний гард ловит только смену
пользователя, не смену поколения того же юзера. Итог: «побеждает последний завершившийся», а не
«последний запрошенный» — возможен кратковременный откат к устаревшим данным
(самоисправляется на следующем reload). Низкий приоритет.

### ⚠️ OPEN · 🟢 LOW
- `loadTodayDashboardSnapshot` и `scheduledReviewDays` (`DeckStore.swift:497`, `:616`) каждый
  зовут `database.loadDecks()` — в today-снапшоте колоды грузятся, затем активные грузятся ещё
  раз внутри forecast-расчёта. Лишний скан, можно переиспользовать.
- Условие полного bootstrap `bootstrapDeviceID == nil && bootstrapSinceRevision == "0"`
  (`AppUserStore.swift`) — логика верная, но стоит подтвердить, что `bootstrapDeviceID`
  действительно `nil` при самом первом синке.
- Подтвердить, что новый `snapshot.todayPracticeCount` (сумма по активным колодам) численно
  совпадает со старым `deckStore.todayPracticeCardCount()`.

### ⚠️ NOTE · 🟢 LOW — порядок открытия read-only vs миграции
`prepareSchemaIfNeeded` выполняется только на `readWrite`-соединении. Read-only снапшот
полагается на то, что схема уже создана/мигрирована на диске (прошлый запуск или RW-соединение
синка раньше в этой сессии). На практике безопасно: `selectedUserID` становится не-nil только
после bootstrap, который создаёт файл/схему через RW-соединение. Но при выкатке новой версии с
новой миграцией есть узкое окно, где read-only снапшот может опередить первую RW-миграцию
сессии — стоит держать в уме при добавлении миграций.

---

## Сводка статуса

| # | Severity | Находка | Статус |
|---|----------|---------|--------|
| 1 | 🔴 HIGH | WAL не включён | ✅ FIXED `7146696` |
| 2 | 🔴 HIGH | normalize/migrations на каждом open | ✅ FIXED `7146696` |
| 3 | 🟡 MEDIUM | снапшот без read-транзакции | ✅ FIXED `7146696` |
| 4 | 🟡 MEDIUM | sync-запрос на main в reloadPracticeCount | ✅ FIXED |
| 5 | 🟡 MEDIUM | перекрывающиеся reload | ⚠️ OPEN |
| 6 | 🟢 LOW | дубль `loadDecks` | ⚠️ OPEN |
| 7 | 🟢 LOW | условие полного bootstrap — проверить | ⚠️ OPEN |
| 8 | 🟢 LOW | равенство подсчёта practiceCount — проверить | ⚠️ OPEN |
| 9 | 🟢 LOW | порядок read-only vs миграции | ⚠️ NOTE |

## Вердикт

Все блокирующие проблемы (обе HIGH + ключевые MEDIUM) закрыты коммитом `7146696`: WAL +
read-only снапшот-соединения + одноразовая подготовка схемы + `readTransaction`. Perf-цель
достигнута без переоткрытия проблемы с другого края. Остаются только мелкие пункты (один
MEDIUM с низким приоритетом + LOW-проверки), не блокирующие.
