# Meu Dia — app pessoal de cuidado

POC de um aplicativo pessoal que reúne medicação, saúde, saúde mental e rotina
num lugar só. Alvo principal: **Android**. O build Web existe para uso no PC,
com paridade de telas e sem alarmes.

- Especificação: [docs/especificacao-tecnica.md](docs/especificacao-tecnica.md)
- Decisões e desvios: [docs/decisoes.md](docs/decisoes.md)

## O que funciona

- Cadastro de remédio com múltiplos horários e dias da semana
- Alarme exato no Android (`AlarmManager`), com ação de reagendamento no boot
  e ao reinstalar/atualizar o app
- Tela **Hoje**: próxima dose, "Já tomei", adiar, pular, lista do dia
- Histórico de doses por slot (append-only, um evento por dose)
- Tarefas com data, categoria e prioridade
- Check-in de humor, gráfico de 7 dias e diário privado
- Consultas e exames, com envio para o Google Calendar
- **Histórico** de doses com adesão de 7 e 30 dias
- **Backup** em JSON (arquivo no aparelho ou download no navegador)
- **Aparência** configurável: 4 paletas e modo claro/escuro/sistema
- Motor de sincronização entre aparelhos (change log + merge + LWW), testado
- Transporte Google Drive: login, pasta `appDataFolder`, envio e recebimento

## O que ainda não funciona

| Item | Situação |
|---|---|
| Validação ponta a ponta do Drive | Código pronto; falta o Client ID Android no Google Cloud e o teste real |
| Conversa diária/semanal | Não implementada (sem LLM, por decisão — ver ADR-003) |
| Anexos (receita, resultado) | Não implementado |
| Relatório PDF | Não implementado |
| Ações na notificação ("Tomei" na tela de bloqueio) | Não implementado; hoje o toque abre o app |

## Estado verificado

Executado nesta máquina em 2026-11-15:

| Verificação | Resultado |
|---|---|
| `flutter analyze` | `No issues found!` |
| `flutter test` | 12 testes, todos passando |
| `flutter build apk --release` | APK de 51,7 MB em `build/app/outputs/flutter-apk/` |
| `flutter build web --release` | `build/web` gerado |
| Manifesto do APK | label `Meu Dia`, minSdk 24, targetSdk 36, compileSdk 37, 7 permissões, receivers de boot presentes |

## O que NÃO foi testado

- Login e upload no Google Drive (falta configurar o projeto OAuth).
- Comportamento em fabricantes agressivos (Xiaomi/Samsung/Motorola) por 8 h.

## Teste em aparelho real (15/11/2026)

Samsung Galaxy A54 (SM-A546E), Android com One UI:

- APK instalado via `adb install` — app abriu na tela **Hoje**.
- Remédio "Losartana" cadastrado pelo próprio celular (08:00 e 11:47, todos os dias).
- `dumpsys alarm` confirmou 4 `RTC_WAKEUP` do pacote
  `br.com.personal_app`, um por dia, no horário certo.
- Alarme de 11:47 disparou e publicou a notificação no canal
  `medication_alarm`, categoria `alarm`, com "Hora do remédio / Losartana às 11:47".
- Os alarmes do dia seguinte foram reagendados automaticamente.

Falta apenas: reagendamento após reiniciar o aparelho e o comportamento com a
tela bloqueada por muitas horas — os dois exigem espera.

## Estrutura

```
lib/
  core/
    models.dart            # entidades + serialização (Dart puro)
    schedule.dart          # cálculo de ocorrências (Dart puro)
    store.dart             # sembast: persistência + change_log
    store_io.dart          # abertura no Android
    store_web.dart         # abertura no navegador (IndexedDB)
    reminders.dart         # interface do agendador
    reminders_android.dart # AlarmManager via flutter_local_notifications
    reminders_stub.dart    # no-op na Web
  ui/                      # telas, tema, componentes
  app_controller.dart      # estado + ações
  main.dart
test/
  schedule_test.dart       # cálculo de doses
  sync_test.dart           # merge entre dispositivos
```

## Ambiente

Instalado em `C:\Dev` pelos scripts em `tools/`:

| Item | Caminho | Versão |
|---|---|---|
| Flutter | `C:\Dev\flutter` | 3.50.0 (Dart 3.14.0) |
| JDK | `C:\Dev\jdk17` | Temurin 17 |
| Android SDK | `C:\Dev\android-sdk` | platform 37.0, build-tools 35/36, NDK 28.2.13676358 |

Abra um terminal novo para herdar o `PATH` gravado no escopo do usuário.

## Configurar o Google Drive

Credenciais no projeto `meu-dia-514815` do Google Cloud:

| Credencial | Uso | Precisa existir |
|---|---|---|
| OAuth **Web** | build Web no PC | origem `http://localhost:8080` |
| OAuth **Android** | app no celular | pacote `br.com.personal_app` + SHA-1 da assinatura |

O Client ID Web está em `lib/core/config.dart`. O Android não entra no código:
o plugin o resolve pelo pacote + SHA-1.

SHA-1 do keystore de debug que assina o APK atual:

```
E6:7F:4A:2A:3C:CC:38:C4:2B:72:3C:38:64:A9:80:D7:79:A2:38:2F
```

Para conferir o SHA-1 de outro keystore:

```powershell
keytool -list -v -keystore "$env:USERPROFILE\.android\debug.keystore" `
  -alias androiddebugkey -storepass android -keypass android
```

A tela de consentimento precisa ter o escopo
`https://www.googleapis.com/auth/drive.appdata` e a sua conta como usuário de
teste, com o app em status **Testing**.

## Rodar

```powershell
flutter pub get
flutter analyze
flutter test
```

### Android

```powershell
flutter build apk --release
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

### Web (PC)

```powershell
flutter build web --release
node tools/serve-web.js 8080
# abra http://localhost:8080
```

A porta **precisa ser 8080**: é a origem autorizada no Client ID Web. Para
desenvolvimento com hot reload, `flutter run -d chrome --web-port 8080` (pare o
servidor estático antes, os dois disputam a porta).

## Ajustes de build que não são óbvios

Três coisas foram necessárias para o APK compilar e para o alarme sobreviver:

1. **`compileSdk = 37`** — `androidx.core:1.19.0` exige API 37. O SDK instala a
   plataforma como `android-37.0`; o AGP 9 resolve pelo `source.properties`.
2. **Core library desugaring** (`desugar_jdk_libs 2.1.4`) — exigido pelo
   `flutter_local_notifications` por causa de `java.time`.
3. **Receivers declarados no manifesto do app** — a versão 23 do plugin não os
   declara sozinha. Sem `ScheduledNotificationBootReceiver`, o alarme é perdido
   ao reiniciar o celular.

## Checklist manual de alarme

1. Cadastrar remédio com horário 2 minutos à frente.
2. Bloquear o celular e esperar: o alarme deve tocar em até 60 s.
3. Tocar na notificação, confirmar "Já tomei" e conferir a lista do dia.
4. Reiniciar o celular e repetir o passo 2.
5. Modo avião por 8 h: o alarme continua funcionando.
6. Em Xiaomi/Samsung/Motorola, conceder isenção de economia de bateria em
   Ajustes → Alertas → Configurar permissões.
