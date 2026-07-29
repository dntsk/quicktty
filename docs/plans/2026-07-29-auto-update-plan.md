# Auto-Updates Implementation Plan

## Зависимость

Sparkle 2.9.4 как embedded framework из официального релиза.
Скачать `Sparkle-for-Swift-Package-Manager.zip` → извлечь xcframework → `Vendor/sparkle/`.

## Изменения

### 1. project.yml — добавить Sparkle

```yaml
dependencies:
  - framework: Vendor/sparkle/Sparkle.framework
    embed: true
settings:
  OTHER_LDFLAGS: "$(inherited) -lstdc++ -framework Sparkle"
```

### 2. Info.plist — ключи Sparkle

В `project.yml` settings добавить:
```yaml
INFOPLIST_KEY_SUEnableAutomaticChecks: YES
INFOPLIST_KEY_SUFeedURL: ""  # переопределяется в рантайме
```

### 3. UpdateManager.swift — враппер

```swift
@MainActor
final class UpdateManager {
    private let defaultFeedURL: URL
    private let betaFeedURL: URL?
    
    var channel: UpdateChannel { ... }
    
    func configureChannel(_ channel: UpdateChannel) // меняет SUFeedURL
    func checkForUpdates()                          // ручная проверка
}
```

Где `UpdateChannel = stable | beta`.

### 4. QuickTTYConfig — updateChannel

Добавить `updateChannel: UpdateChannel = .stable`.
Ключ: `quicktty-update-channel`.
При первом запуске: если имя версии содержит `-beta` → `.beta`.

### 5. Appcast генерация

В `scripts/build-release.sh` добавить вызов `generate_appcast`:
- Скачивается Sparkle CLI tools
- Генерится `appcast.xml` из DMG + release notes
- Публикуется отдельным asset в GitHub Release

### 6. Меню

Добавить `Check for Updates…` в AppKit меню, делегирует в `UpdateManager.checkForUpdates()`.

### 7. Бета-канал

Бета-фид публикуется в отдельный path GitHub Release (или отдельный тег).
`make release-beta` — сборка + нотаризация + публикация бета-фида.

## Логика канала

```
Первый запуск:
  - версия содержит "beta" → канал beta
  - иначе → канал stable

Обновление:
  - stable-фид: только stable-релизы
  - beta-фид: все prereleases текущей мажорной версии

Переключение канала в конфиге:
  - меняет SUFeedURL в рантайме
  - немедленная проверка обновлений
```

## Не входит в MVP

- Delta-обновления (требуют отдельной настройки generate_appcast)
- AutoUpdate.app в DMG (обновление без пароля)
- Инкрементальные бинарные патчи
