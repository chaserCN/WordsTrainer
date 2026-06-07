# Аудит: программа в целом + причёсанный sync-протокол

**Дата:** 2026-06-06 (вечер)
**Область:** `client/Words Trainer` (iOS) целиком, с фокусом на новый протокол sync.
**Режим:** read-only, код не менялся.
**HEAD на момент аудита:** `4c21fcb "Adopt clean sync protocol on iOS"`.

**Связанные документы:**
- `audit/2026-06-01-client-bugs-and-sync.md` (предыдущий — многое из него уже исправлено, см. ниже)
- `audit/2026-06-06-performance-db-offmain.md` (perf, WAL/read-only снапшоты)

---

## Вердикт

Кодовая база за последние часы заметно повзрослела: параллельная сессия закрыла **все 3
Critical** и часть High из аудита 2026-06-01, а sync-протокол переведён на чистую вложенную
схему. Транспорт и семантика sync сейчас в хорошем состоянии. Остаются: **outbox-строки для
ставших неактивными карт зависают**, **продуктовая неоднозначность matching ↔ FSRS**, и общий
**tech debt в `ContentDatabase`** (god-object на 3k строк сырого SQLite).

---

## 1. Причёсанный протокол — проверка ✅

### Что изменилось (`4c21fcb`)
| Эндпойнт | Новая форма |
|----------|-------------|
| `GET /v1/bootstrap` | `{ revision, user, users, snapshot: { assignments, content, media, progress, reviews, … } }` |
| `GET /v1/sync/changes?sinceRevision=` | `{ toRevision, changes: { … те же группы … } }` |
| `POST /v1/sync/events` (ответ) | `{ accepted:{…}, duplicates:{…}, rejected:{…}, toRevision }` со сгруппированными `*Ids` |

Убраны: `dailyUsage` / `hasDailyUsageSnapshot` из bootstrap, query-параметр `sinceRevision` у
bootstrap, заголовок `X-FlashGame-Time-Zone`.

### Оркестровка (`AppUserStore.refreshFromServer`)
- Полный `bootstrap` до завершения первого sync; далее — дельта `/sync/changes`.
- Гейт перехода на дельту: `hasCompletedInitialSync() && localServerRevision != "0" && !users.isEmpty`.
- `bootstrap` → `importServerBootstrap` (`replaceAssignments` + полный reconcile),
  `changes` → `importServerChanges` (`upsertAssignments`, без reconcile).

### Корректность — подтверждено
- **Reconcile удалений** (`deleteSyncedProgressMissingFromServerSnapshot`) выполняется только на
  первом полном bootstrap (гейт `!hasCompletedInitialSync`). После — удаления приходят
  **только** через `studyDataResets`-маркеры (`applyStudyDataResets` → `deleteSyncedStudyData`).
  → это **закрывает находку #6** прошлого аудита (раньше условие почти всегда было false).
- Reset удаляет **только** `synced_at IS NOT NULL` — незагруженная локальная работа сохраняется;
  `deckId == nil` = сброс всех колод пользователя. Аккуратно.
- **`dailyUsage` теперь выводится локально** из `study_reviews` в `rebuildDerivedStats`
  (`DELETE deck_daily_usage` + `INSERT … SELECT SUM(was_new AND correct)`). Поскольку reviews
  синхронизируются идемпотентно (`ON CONFLICT(id)`), счётчик новых карт восстанавливается из них
  — убирать его с провода корректно, это упрощение, а не регресс.
- **Отозванные назначения в дельте**: `upsertAssignments` пишет реальный
  `assignment.assignmentStatus`, запросы фильтруют `status = 'active'` → revoke применится, если
  сервер прислал изменённую строку назначения.
- Ошибки декодирования теперь специфичны: `invalidResponse("sync/changes decode: …")` —
  частично закрывает находку #26.

### Риски протокола

| # | Severity | Находка |
|---|----------|---------|
| P1 | 🟡 MEDIUM | **После initial-sync удаления зависят на 100% от маркеров/статусов в дельте.** Reconcile-сетки больше нет. Если сервер хоть раз не пришлёт удаление/revoke в delta, клиент будет держать stale-данные до повторного полного bootstrap (а он бывает только если `revision="0"` или сброшен флаг initial-sync). **Реко:** периодический/принудительный full bootstrap как safety-net (или кнопка «полная пересинхронизация»). |
| P2 | 🟢 LOW | Дельта-путь рапортует `finishSync(.loaded(assignmentCount: changes.assignments.count …))` — это **размер дельты**, не суммарные значения. Проверить, что это только для статус-текста и не подставляется в UI (иначе после дельты «0 назначений»). |
| P3 | 🟢 LOW (perf) | `rebuildDerivedStats` делает полный `DELETE` + `INSERT…SELECT` по всем `study_reviews` на **каждом** sync, включая дельты — O(вся история). Сейчас ок, следить при росте истории. |
| P4 | 🟢 NOTE | Убран `X-FlashGame-Time-Zone` из bootstrap — подтвердить, что серверные суточные расчёты от него больше не зависят (daily usage теперь клиентский, так что скорее всего ок). |
| P5 | 🟢 LOW | Декодеры стали жёстче: `nestedContainer(forKey: .snapshot/.changes/.accepted/.duplicates/.rejected)` — **обязательные**. Если сервер опустит любую из этих групп (а не пришлёт `{}`), декод бросит. Старая плоская схема была мягче (`decodeIfPresent`). Зафиксировать в контракте: группы всегда присутствуют, пусть и пустыми. |

---

## 2. Статус находок аудита 2026-06-01

| # | Sev | Находка | Статус сейчас |
|---|-----|---------|---------------|
| 1 | Crit | submit глотает ошибки save | ✅ **FIXED** — `submit()` показывает `sessionError`, не глотает |
| 2 | Crit | смена юзера → запись под чужим user_id | ✅ **FIXED (по данным)** — `validateCurrentUser()` бросает перед записью; авто-dismiss не делается, но порчи данных нет |
| 3 | Crit | одна битая FSRS-строка рушит колоду | ✅ **FIXED** — `progressMap` декодит построчно, чинит в `CardProgress.newCard`, персистит |
| 6 | High | reset прогресса не доезжает | ✅ **FIXED** — флаг `initialSyncCompleted` + `studyDataResets`-маркеры |
| 7 | High | пропавшие медиа без самовосстановления | ✅ **FIXED** — `cachedDeckVersionIDs` отдаёт версию только если `cachedDeckMediaIsComplete` (файлы на диске) |
| 12/22 | Med | matching completion desync | 🔶 **вероятно улучшено** (`1640548` упростил поток, удалил код в `StudySession`/`MatchingColumnsStudyView`) — перепроверить пустой борд (0 пар) вручную |
| 8 | High | outbox: practice/progress/matching фильтруют по active card | ⚠️ **OPEN** (см. ниже) |
| 4,5 | High | matching ↔ FSRS семантика практики | ⚠️ **OPEN** (продуктовое) |
| 9 | High | старт сессии без обратной связи | ⚠️ карри-овер, не перепроверял |
| 10,11 | High | атомарность upload / pre-bootstrap failure | ⚠️ карри-овер, не перепроверял |
| 13,18,19,прочее Medium/Low | — | ⚠️ карри-овер, не перепроверял отдельно |

> Перепроверены лично: 1, 2, 3, 6, 7, 8 и весь протокол. Остальные — по диффам коммитов не
> выглядят затронутыми, но требуют отдельной проверки.

---

## 3. Подтверждённые открытые находки

### ⚠️ OPEN · 🟡 HIGH — #8 outbox: события для неактивных карт зависают навсегда
`ContentDatabase.swift`:
- `pendingReviewEvents` (1170) — фильтр только `user_id` + `synced_at IS NULL` (без join) → reviews уходят всегда. ✅
- `pendingPracticeReviews` (1236-1238), `pendingProgressItems` (~1290), matching — `JOIN cards … WHERE cards.status = 'active'`.

Если карта/колода стала `inactive` локально (новая версия контента, revoke) **до** того как её
practice/progress/matching-строки выгрузились, эти строки больше **никогда** не попадут под
фильтр (`synced_at` останется NULL навсегда) → тихая потеря аналитики/прогресса на сервере.
**Фикс:** выровнять с `pendingReviewEvents` (грузить независимо от текущего статуса карты) или
ввести явный TTL/cleanup для безнадёжных строк.

### ⚠️ OPEN · 🟡 MEDIUM — #4/#5 matching ↔ FSRS (продуктовое)
Верные пары в «Колонках» не дают FSRS-бенефита, ошибки в «практике» всё равно пишут прогресс.
Нужно продуктовое решение: либо non-SRS игра, либо `.good` на correct (throttled), либо явное
предупреждение в UI. Без него режим штрафует без выгоды.

---

## 4. Программа в целом — архитектура и tech debt

**Сильные стороны**
- Чёткая модель потоков: `@MainActor DeckStore` для записи + `Task.detached` read-only снапшоты
  для дашборда + WAL (см. perf-аудит). Гонок на соединении нет.
- `Sendable`-снапшоты, аккуратный дебаунс перезагрузок, фокус-менеджмент в UI.
- Идемпотентность reviews, LWW прогресса/preferences, защита незагруженной локальной работы при
  reset — зрелая семантика sync.
- Есть тесты в `SPMTest` (`ContentDatabaseTests`, `ServerSyncClientTests`,
  `MatchingPairSchedulerTests`), которые растут вместе с фиксами.

**Tech debt / риски сопровождения**
| # | Severity | Находка |
|---|----------|---------|
| A | 🟡 MEDIUM | **`ContentDatabase.swift` — god-object на 2990 строк**: открытие/миграции + импорт sync + outbox + медиа + статистика + нормализация. Тяжело тестировать и менять. Кандидат на расщепление (Schema / SyncImport / Outbox / MediaCache / Stats). |
| B | 🟡 MEDIUM | **Сырой SQLite-boilerplate** (`prepare`/`bind`/`step`/`finalize`) повторяется в десятках мест → легко ошибиться с индексами bind / забыть `finalize`. Тонкий хелпер (или GRDB) убрал бы целый класс багов. |
| C | 🟢 LOW | Крупные view-файлы: `DashboardViews.swift` 2555, `DeckListView.swift` 1605, `MatchingColumnsStudyView.swift` 940 — стоит дробить по экранам/компонентам. |
| D | 🟢 LOW | Дублирование схемы импорта между `importServerBootstrap` и `importServerChanges` (почти идентичные последовательности upsert) — вынести общий приватный применятор, различающийся только `replace` vs `upsert` назначений и reconcile-шагом. |
| E | 🟢 LOW | Карри-овер Low из 2026-06-01 (#27-#35): мёртвый `clozeTyping`, проглатываемые ошибки в `saveUsers`/`syncPendingEventsToServer`, `ContentDatabaseError` не `LocalizedError`, и т.д. |

---

## Рекомендуемый порядок

1. **#8** — выровнять outbox-фильтры (риск тихой потери данных). HIGH.
2. **P1** — safety-net полный bootstrap / кнопка пересинхронизации (защита от пропущенных
   маркеров удаления в дельте). MEDIUM.
3. **#4/#5** — продуктовое решение по matching ↔ FSRS. MEDIUM.
4. Ручная проверка matching completion на пустом борде (#12/#22).
5. Tech debt A/B (расщепление `ContentDatabase`, SQLite-хелпер) — по мере появления времени.

---

## Сводка

| Severity | Open сейчас | Закрыто с 2026-06-01 |
|----------|-------------|----------------------|
| Critical | 0 | 3 (#1, #2, #3) |
| High | 1 подтверждён (#8) + карри-овер на проверку | 2 (#6, #7) |
| Medium | #4/#5 + P1 + tech debt A/B | #12/#22 улучшено |
| Low | P2-P5, C/D/E | — |

Протокол причёсан корректно; критичных дыр в новой схеме не нашёл. Главный остаточный риск
данных — #8 (зависающие outbox-строки) и P1 (отсутствие reconcile-сетки в дельта-режиме).
