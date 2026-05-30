# Words Trainer SPMTest

`SPMTest` — отдельный Swift Package для быстрых тестов логики без Xcode app target.

## Симлинки

- `Models/` → `../Words Trainer/Models`
- `SRS/` → `../Words Trainer/SRS`

Файлы в симлинках — **оригинальные исходники приложения**, не копии. Правки через `SPMTest/Models/...` или `SPMTest/SRS/...` меняют код в app target.

`Package.swift` явно перечисляет, какие файлы собирать (Views, Services с UI/SQLite не включены).

## Запуск

```bash
cd "client/Words Trainer/SPMTest"
swift test
```

Или открыть `Package.swift` в Xcode и запустить `WordsTrainerLogicTests`.

## Что тестируется

- разбор переводов по `;` (`WordCardContent`, `MatchingPair`)
- алгоритм колонок (`StudySession` — без дубликатов одного слова на экране)
- SRS-очередь и статистика колоды
