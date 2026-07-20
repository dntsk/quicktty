# Handoff: падение Config tab при повторном mount

## Результат

Исправлен баг, при котором Config tab с `nano` исчезал после переключения на другой tab и возврата.

Пользователь вручную подтвердил исправление на свежей Debug-сборке: сценарий `Cmd+,` → другой tab → Config → ввод клавиши работает.

## Причина

При повторном mount `GhosttySurfaceView.synchronizeSurfaceSize()` отправлял в Ghostty transient AppKit layout размером около `1×1`. Ghostty передавал соответствующий PTY resize foreground-процессу. Независимый PTY-тест подтвердил, что последовательность `normal → 1×1 → normal` приводит `nano` к `SIGSEGV`; process-exit callback затем штатно удалял tab.

## Исправление

- `GhosttySurfaceView` не отправляет размеры, консервативно дающие terminal grid меньше 5 columns × 2 rows.
- Расчёт защищён от zero cell metrics, non-finite значений и integer overflow; fallback — 40×32 px.
- DEBUG resize observations ограничены 256 записями.
- Добавлены boundary, backing-scale, overflow, ring-buffer и remount regression tests.
- Добавлен size-sensitive child process, завершающийся при опасном `SIGWINCH`, чтобы проверять root swap без зависимости от `nano`.

## Коммиты

- `d036704 fix: ignore transient tiny terminal sizes`
- `2da799d test: harden transient terminal resize guard`

## Проверки

- `GhosttySurfaceViewTests` + `GhosttySplitTreeViewTests` — два последовательных прогона успешны.
- `WindowCoordinatorTabLifecycleTests` — 52/52.
- `make build` — успешно.
- `make lint` и callback-contract — успешно.
- `git diff --check` — успешно.
- Повторный code review — `APPROVED`.
- Ручная runtime-проверка пользователя — успешно.

## Состояние

- `main` чистый после коммитов, кроме этого handoff-файла до его фиксации в следующей работе.
- Запущена свежая Debug-сборка из `.build/DerivedData/Build/Products/Debug/GhostTerm.app`, PID на момент проверки `93148`.
- Приложение не завершать без запроса пользователя.

## Следующие задачи

- Surface init/render failure placeholder с `Retry / Close Pane`.
- Остатки theme integration.
- Multi-tab drag выбранных tabs.
- Полная durability-проверка workspaces/tabs/splits/CWD.
- Release milestone и стабилизация известных flaky tests.
