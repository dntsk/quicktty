# QuickTTY appcasts

`beta.xml` — единственный публичный beta feed QuickTTY. Приложение получает его по адресу:

`https://raw.githubusercontent.com/dntsk/quicktty/master/docs/appcasts/beta.xml`

Не редактируйте XML вручную. После публикации и анонимной проверки каждого beta release выполните `make beta-feed`: команда проверит final DMG и generated appcast, затем атомарно скопирует exact appcast в этот файл. Просмотрите diff, создайте отдельный commit и push только после успешной публичной проверки.

Enclosure должен ссылаться на immutable DMG конкретного `v<version>` GitHub Release. Нельзя заменять, удалять или загружать assets в уже опубликованный release.
