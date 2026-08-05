# Handoff: единое оформление hotkeys в документации

- **Дата:** 2026-08-05
- **Ветка:** master
- **Статус дерева:** чистое после коммита и push

## Выполнено

- В `site/docs/index.html` пользовательские сочетания клавиш в разделах Tabs/Splits/Workspaces, Broadcast Input и Search переведены с inline `<code>` на семантический `<kbd>`.
- Написание сочетаний приведено к стилю существующих таблиц: `Cmd+T`, `Cmd+Shift+D` и т. п.
- Конфигурационный синтаксис и его inline `<code>` не изменялись.

## Проверки

- `python3 scripts/check-site.py` — PASS, проверены 4 HTML-страницы.
- `git diff --check` — PASS.
- `rg -n '<code>(cmd|Cmd)[^<]*</code>' site/docs/index.html || true` — пользовательских hotkeys в `<code>` не осталось; найден только пример canonical config grammar.

## Незавершённое

- Нет.

## Следующий шаг

1. Дополнительных действий не требуется.

## Важный контекст

- `<kbd>` уже имел готовый единый стиль в `site/assets/styles.css`, поэтому CSS менять не потребовалось.
