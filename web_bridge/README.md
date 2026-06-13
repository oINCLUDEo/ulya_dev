# Telegram OAuth bridge (`tg-mobile.html`) — ЗАПАСНОЙ вариант

> ⚠️ **Этот мост больше не нужен в основном сценарии.** Приложение использует
> **Native Login** (Authorization Code flow): Telegram отдаёт `code` прямо на
> зарегистрированную в @BotFather кастомную схему `ulyavpn://oauth/telegram`,
> без какой-либо веб-страницы. Файл оставлен как запасной вариант на случай,
> если на каком-то устройстве нативный редирект не сработает. Деплоить его
> не обязательно.

Маленькая статическая страница-мост для входа в мобильное приложение **Ulya VPN**
через настоящий Telegram OAuth (`oauth.telegram.org`) — тот же механизм, что у
веб-кабинета, а не deep-link бота.

## Зачем

Telegram OAuth жёстко привязан к **одному домену на бота** — тому, что прописан в
`@BotFather` (`/setdomain`). Результат авторизации Telegram отдаёт во **фрагменте
URL** (`#...`), который виден только JavaScript на странице того же домена.
Поэтому мобильному приложению нужна страница на этом домене, которая поймает
результат и вернёт его в приложение через `ulyavpn://oauth/telegram`.

## Куда деплоить

На домен, прописанный в `@BotFather` для этого бота. Сейчас это **`web.ulya.space`**
(там же живёт OIDC кабинета). Файл должен открываться по адресу:

```
https://web.ulya.space/tg-mobile.html
```

Этот URL зашит в приложении: `AppConfig.telegramBridgeUrl`.

Достаточно положить `tg-mobile.html` рядом со статикой кабинета (тот же origin).
Никакого бэкенда не требуется — страница полностью самодостаточна.

## Конфигурация внутри файла

В начале `<script>` заданы константы — поменяйте, только если сменится бот/домен:

| Константа | Значение | Что это |
|-----------|----------|---------|
| `BOT_ID`  | `8762640503` | Числовой id `@include_project_bot` (префикс токена бота, публичный) |
| `ORIGIN`  | `https://web.ulya.space` | Должен совпадать с доменом из BotFather |
| `RETURN`  | `ORIGIN + '/tg-mobile.html'` | URL самой этой страницы |
| `APP_CB`  | `ulyavpn://oauth/telegram` | = `AppConfig.telegramAuthCallback` |

## Как это работает

1. Приложение открывает `tg-mobile.html` во встроенном браузере
   (`flutter_web_auth_2`, scheme `ulyavpn`).
2. Страница редиректит на `oauth.telegram.org/auth`; пользователь подтверждает
   вход в Telegram.
3. Telegram возвращает результат на `tg-mobile.html` (фрагмент с `tgAuthResult`
   или `id_token`).
4. Страница отдаёт результат приложению: `ulyavpn://oauth/telegram?tgAuthResult=…`
   (или `?id_token=…`, или `?error=…`).
5. Приложение шлёт `id_token` на `POST /cabinet/auth/telegram/oidc`, а widget-данные
   на `POST /cabinet/auth/telegram/widget`, получает JWT-пару и сохраняет сессию.

Если `oauth.telegram.org` недоступен/заблокирован, приложение автоматически
откатывается на вход через deep-link бота (`/mobile/v1/auth/init`).
