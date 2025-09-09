# P2P Call — Address Book (Whitelist)

Идея: участники один раз обмениваются ключами (QR/копипаста), контакт сохраняется в адресную книгу.
Дальше можно звонить по имени контакта без повторного обмена оффер/ответ.

## На сервере
запущено 2 сервиса
1. sudo systemctl status coturn
2. sudo systemctl status pphone-signal

## Поток действий
1. Откройте вкладку Contacts → Onboarding → обменяйтесь карточками (QR или копипаста).
2. Контакт появится в адресной книге (`contacts.json`).
3. На вкладке Calls видны контакты и онлайн-статус (mDNS).
4. Нажмите Call, чтобы инициировать звонок (MVP).

## TODO
- Реальный Noise IK/XK и derive SRTP/SFrame.
- Мини-сервер WebSocket для интернета.
- Ultra-Low BW профиль Opus.
