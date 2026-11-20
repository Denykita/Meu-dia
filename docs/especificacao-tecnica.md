# Especificação Técnica — App Pessoal de Cuidado

**Versão:** 0.1 (POC)
**Data:** 2026-11-15
**Status:** proposta para revisão — nada implementado

---

## 1. Objetivo

Aplicativo pessoal que apoia o dia a dia de uma pessoa (com foco em idoso), cobrindo quatro
frentes integradas:

1. **Medicação** — lembrar, confirmar, cadastrar, histórico.
2. **Saúde** — consultas, exames, resultados, recomendações, exercícios.
3. **Saúde mental** — check-in de humor, diário privado, detecção de desânimo, sugestão de atividade.
4. **Rotina** — tarefas diárias, resumo semanal/mensal, conversa guiada.

O diferencial não é ter as quatro coisas: é **uma conversa diária com contexto das quatro**.

---

## 2. Princípios de arquitetura

### P1. Android é o produto. O PC é uma tela maior.

**Paridade total de funcionalidades no Android.** Toda capacidade existe no celular, sem exceção:
cadastro de medicamento e receita, anexo de exame, geração de relatório, configuração, exportação.
O app Web existe para conforto (teclado, tela grande), nunca como pré-requisito.

Consequências diretas:

- A UI é desenhada **phone-first** e adaptada para telas largas. Não existe tela "só desktop".
- A câmera do celular é o melhor scanner de receita — o fluxo principal de receita é no Android.
- Relatório para o médico é gerado no aparelho e compartilhado pela folha nativa de compartilhamento.
- Nenhuma tarefa de configuração exige passar pelo PC.

### P2. Offline-first absoluto

O banco local é a fonte da verdade. O lembrete de remédio **nunca** depende de rede, de sync ou
de nuvem. Se o Google Drive estiver fora, o app continua idêntico por tempo indeterminado.

### P3. Alarme local, agendado no aparelho

Cada dose é um alarme persistido no `AlarmManager`. A sincronização replica o *esquema* de doses;
o *alarme* é sempre local.

### P4. O diário é inviolável

Nenhuma projeção, relatório, exportação compartilhada ou análise inclui o texto do diário.
Isso é regra de produto, não configuração.

### P5. Privacidade por padrão

Tudo nasce `private`. Compartilhar é ação explícita e por entidade. O compartilhamento é uma
**projeção com allowlist**, não uma filtragem do banco inteiro.

### P6. Um usuário, sem backend

POC não tem servidor, não tem multiusuário, não tem push. O Drive é transporte de arquivos,
não banco de dados.

---

## 3. Arquitetura de alto nível

```
┌─────────────────────────────┐        ┌─────────────────────────────┐
│  ANDROID (Flutter nativo)   │        │  WEB (Flutter, localhost)   │
│  ─ alvo principal           │        │  ─ tela opcional            │
│  ─ alarmes + notificações   │        │  ─ sem alarme               │
│  ─ câmera / compartilhar    │        │  ─ layout largo             │
│                             │        │                             │
│  SQLite (drift)             │        │  SQLite WASM (drift)        │
│         │                   │        │  IndexedDB / OPFS           │
└─────────┼───────────────────┘        └───────────────┼─────────────┘
          │                                            │
          └──────────────────┬─────────────────────────┘
                             ▼
                 Google Drive · appDataFolder
                 ├── manifest.json
                 ├── log/<deviceId>/<AAAA-MM>.jsonl
                 └── attachments/<sha256>.<ext>
```

Camadas (uma única app Flutter, sem monorepo no POC):

```
lib/
  main.dart
  core/
    platform/          # interfaces + implementações por alvo
    db/                # drift: schema, migrações, DAOs
    sync/              # log, merge, Drive
    ui/                # tema, tipografia, componentes acessíveis
    util/              # ULID, clock, datas
  features/
    onboarding/
    today/             # tela "Hoje"
    medication/
    health/
    mind/
    tasks/
    daily/             # conversa diária/semanal
    settings/
```

Regra de dependência: `features` → `core` → nunca o contrário. `core/platform` define interfaces;
`core/platform/android` e `core/platform/web` implementam.

> **Por que não monorepo agora:** um único pacote com camadas explícitas dá o mesmo isolamento
> com muito menos atrito. Extrair `domain`/`data` para pacotes é refatoração barata depois.

---

## 4. Stack

| Camada | Escolha | Motivo |
|---|---|---|
| Framework | Flutter (Android + Web) | Um codebase, dois alvos |
| Banco | **drift** sobre SQLite / SQLite WASM | Tipado, migrações reais, roda nos dois alvos |
| Estado | Riverpod | Testável, sem `BuildContext` no domínio |
| Navegação | go_router | Rotas compartilhadas, deep link |
| Notificação/alarme | `flutter_local_notifications` + `timezone` | Alarme exato no Android e ações na notificação |
| Background | `workmanager` | Detecção de dose perdida, resumo matinal, retry de sync |
| Auth/Drive | `google_sign_in` + `googleapis` | Escopo `drive.appdata` |
| Segredos | `flutter_secure_storage` (Android) | Token nunca em texto puro |
| Anexos | `image_picker` + compressão local | Receita e resultado de exame |
| Relatório | `pdf` + `share_plus` | PDF gerado no aparelho |
| Criptografia local | `sqlcipher_flutter_libs` (opcional, fase 2) | Banco cifrado em repouso |

Versões exatas são fixadas no `pubspec.yaml` no início da implementação; não fazem parte desta spec.

---

## 5. Modelo de dados

### 5.1 Convenções

- **IDs:** ULID em texto — ordenável por tempo, seguro para merge entre dispositivos.
- **Tempo:** ISO-8601 UTC no armazenamento (`TEXT`), conversão para `America/Sao_Paulo` na UI.
- **Exclusão:** sempre lógica (`deleted_at`), nunca `DELETE` físico — necessário para o sync propagar.
- **Autoria:** toda tabela mutável tem `updated_at`, `device_id`, `deleted_at`, `visibility`.
- **Visibilidade:** `private` | `shareable`. Default `private`.

### 5.2 Entidades

**Cadastro (mutável, LWW no merge)**

```sql
medication(
  id TEXT PK, name TEXT NOT NULL, dosage TEXT, form TEXT,
  instructions TEXT, color TEXT, active INTEGER DEFAULT 1,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

medication_schedule(                  -- um horário por linha
  id TEXT PK, medication_id TEXT NOT NULL,
  time_local TEXT NOT NULL,           -- 'HH:mm'
  days_mask INTEGER NOT NULL,         -- bitmask seg..dom
  start_date TEXT, end_date TEXT,
  dose_amount TEXT,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)
-- índice único (medication_id, time_local, days_mask) WHERE deleted_at IS NULL

prescription(
  id TEXT PK, medication_id TEXT, issued_by TEXT, issued_at TEXT,
  notes TEXT, attachment_id TEXT,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

appointment(
  id TEXT PK, kind TEXT,             -- 'consultation' | 'exam' | 'other'
  title TEXT NOT NULL, professional TEXT, place TEXT,
  scheduled_at TEXT NOT NULL, notes TEXT,
  status TEXT DEFAULT 'scheduled',   -- 'scheduled' | 'done' | 'canceled'
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

exam_result(
  id TEXT PK, appointment_id TEXT, title TEXT, result_at TEXT,
  summary TEXT, attachment_id TEXT,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'   -- default private: resultado é sensível
)

recommendation(
  id TEXT PK, source TEXT, text TEXT, active INTEGER DEFAULT 1,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

exercise(
  id TEXT PK, title TEXT, description TEXT, frequency TEXT,
  active INTEGER DEFAULT 1,
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

task(
  id TEXT PK, title TEXT NOT NULL, notes TEXT,
  due_at TEXT, priority INTEGER DEFAULT 0,
  category TEXT,                     -- 'health' | 'bills' | 'personal'
  recurrence TEXT,                   -- RRULE simplificado, nullable
  status TEXT DEFAULT 'open',        -- 'open' | 'done' | 'canceled'
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

attachment(
  id TEXT PK, owner_type TEXT, owner_id TEXT,
  sha256 TEXT NOT NULL, mime TEXT, bytes INTEGER,
  local_path TEXT,                   -- caminho no aparelho
  remote_key TEXT,                   -- nome no Drive após upload
  created_at TEXT, updated_at TEXT, device_id TEXT,
  deleted_at TEXT, visibility TEXT DEFAULT 'private'
)

setting(key TEXT PK, value TEXT, updated_at TEXT)
```

**Eventos (imutáveis, união no merge — nunca conflitam)**

```sql
dose_event(
  id TEXT PK,                        -- ULID, ordena por tempo
  medication_id TEXT NOT NULL, schedule_id TEXT,
  planned_at TEXT NOT NULL,
  status TEXT NOT NULL,              -- 'taken' | 'skipped' | 'postponed' | 'missed'
  acted_at TEXT NOT NULL,
  note TEXT,
  device_id TEXT, created_at TEXT
)
-- índice único (schedule_id, planned_at) para impedir dupla confirmação

mood_checkin(
  id TEXT PK, at TEXT NOT NULL,
  mood INTEGER NOT NULL,             -- 1..5
  energy INTEGER,                    -- 1..5
  tags TEXT,                         -- csv curto
  note TEXT,                         -- privado, nunca vai para projeção
  device_id TEXT
)

diary_entry(
  id TEXT PK, at TEXT NOT NULL, text TEXT NOT NULL,
  local_only INTEGER DEFAULT 1,      -- 1 = não sobe para a nuvem
  device_id TEXT
)

exercise_log(id TEXT PK, exercise_id TEXT, at TEXT, device_id TEXT)

chat_message(
  id TEXT PK, thread_id TEXT NOT NULL,   -- 'daily' | 'weekly'
  role TEXT NOT NULL,                    -- 'user' | 'assistant'
  content TEXT NOT NULL, at TEXT NOT NULL, device_id TEXT
)

change_log(                          -- unidade de sincronização (ver §6)
  seq INTEGER PK AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,           -- ULID
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op TEXT NOT NULL,                  -- 'upsert' | 'delete' | 'event'
  payload TEXT NOT NULL,             -- JSON do registro
  at TEXT NOT NULL,
  device_id TEXT NOT NULL,
  synced INTEGER DEFAULT 0
)
```

### 5.3 Derivados (não persistidos)

- **Adesão** = `dose_event` agrupado por dia/medicamento sobre `medication_schedule`.
- **Próxima dose** = próxima ocorrência não coberta por `dose_event`.
- **Tendência de humor** = média móvel de `mood_checkin` (7 e 30 dias).
- **Sinal de desânimo** = regra local, sem LLM no POC (ver §10).

---

## 6. Sincronização

### 6.1 Princípio

O `change_log` é a unidade. Toda mutação local grava uma linha **na mesma transação** que altera a
tabela. O estado local é a aplicação ordenada do log. Sincronizar = unir logs, não comparar tabelas.

### 6.2 Formato no Drive

```
appData/
  manifest.json                      # { schemaVersion, lastRevision, updatedAt, devices[] }
  log/<deviceId>/<AAAA-MM>.jsonl     # uma linha JSON por entrada de change_log
  attachments/<sha256>.<ext>
  snapshot/<revision>.json           # opcional, compactação
```

`appDataFolder` é privada do app: nem você a vê no Drive, nem outro usuário acessa. Isso é
desejável para privacidade e é a razão técnica de o compartilhamento exigir outro mecanismo (§11).

### 6.3 Fluxo

1. **Pull** — lista `log/`, baixa arquivos com `modifiedTime` maior que o último pull, faz parsing
   e ordena por `(at, device_id, id)`.
2. **Merge** — aplica entradas não presentes localmente (dedupe por `change_log.id`).
   - `op = event` (append-only): insere se o ID não existir.
   - `op = upsert`: vence o maior `updated_at`; empate desempata por `device_id`.
   - `op = delete`: apenas marca `deleted_at`.
3. **Push** — envia linhas `synced = 0` no arquivo do mês corrente do próprio device,
   anexando ao final (nunca reescrevendo o arquivo de outro dispositivo).
4. **Marcar** `synced = 1` e atualizar `manifest.lastRevision`.

### 6.4 Gatilhos

- Abertura do app.
- Retorno do background.
- Após mutação, com debounce de 30 s.
- Job periódico do WorkManager (a cada 6 h, best-effort).
- Manual, no botão "Sincronizar agora".

### 6.5 Falha e conflito

Falha é silenciosa para o usuário (badge discreto "pendente de sync"). Detalhes em Ajustes.
Conflito real é improvável com um usuário; a regra LWW é suficiente e determinística.

### 6.6 Compactação

Quando o total de linhas passar de ~5.000, gerar `snapshot/<revision>.json` com o estado
materializado e podar logs anteriores. Não é necessário no dia 1.

---

## 7. Interfaces de plataforma

```dart
// core/platform/reminder_scheduler.dart
abstract interface class ReminderScheduler {
  Future<void> ensurePermissions();          // notificação, alarme exato, bateria
  Future<void> schedule(ReminderRequest r);  // uma dose
  Future<void> cancel(String scheduleId);
  Future<void> rescheduleAll(List<ReminderRequest> all); // pós-boot, pós-sync, pós-update
  Future<List<String>> pending();
}

// core/platform/cloud_sync.dart
abstract interface class CloudSync {
  Future<bool> signIn();
  Future<void> signOut();
  Future<SyncOutcome> syncNow();
  Stream<SyncState> watch();                 // idle | syncing | offline | error
}

// core/platform/secure_store.dart
abstract interface class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

// core/platform/attachment_store.dart
abstract interface class AttachmentStore {
  Future<AttachmentRef> saveLocal(File source);       // hash + cópia local
  Future<File?> open(AttachmentRef ref);
  Future<void> uploadPending();
}

// core/platform/report_exporter.dart
abstract interface class ReportExporter {
  Future<File> buildDoctorReport(ReportPeriod period);
  Future<void> share(File pdf);                       // share_plus
}
```

Implementações:
`core/platform/android/*` e `core/platform/web/*`, selecionadas por import condicional.
No Web, `ReminderScheduler` é um **no-op explícito** que retorna `unsupported` — a UI mostra
"alertas só no celular", nunca falha silenciosa.

---

## 8. Comportamento Android

### 8.1 Permissões no manifesto

| Permissão | Uso |
|---|---|
| `POST_NOTIFICATIONS` | Android 13+ |
| `SCHEDULE_EXACT_ALARM` / `USE_EXACT_ALARM` | Alarme exato (12+) |
| `RECEIVE_BOOT_COMPLETED` | Reagendar após reiniciar |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Fabricantes agressivos |
| `USE_FULL_SCREEN_INTENT` | Alarme crítico em tela cheia |
| `CAMERA` (via picker) | Foto de receita |
| `INTERNET` | Sync |

### 8.2 Onboarding de permissões

Tela única, em linguagem simples, com um cartão por permissão e explicação do *porquê*:
"Para o alarme do remédio tocar mesmo com o celular bloqueado". Cada cartão tem botão de ação
e estado (concedido / pendente). O app funciona parcialmente sem elas, mas avisa o risco.

### 8.3 Alarme

- `zonedSchedule` com `AndroidScheduleMode.exactAllowWhileIdle`.
- Canal `medication_alarm`, importância `max`, som próprio, vibração, categoria `alarm`.
- Ações na notificação: **Tomei** · **Adiar 10 min** · **Pular**.
- Se não houver ação em 15 min: reemite em modo insistente e registra `dose_event.missed`.
- `USE_FULL_SCREEN_INTENT` apenas para o alarme principal, nunca para tudo.

### 8.4 Boot e atualização

Receiver de `BOOT_COMPLETED` e `MY_PACKAGE_REPLACED` chama `rescheduleAll` a partir do banco local.
Esse é o teste que mais falha em apps do tipo — entra nos critérios de aceite.

### 8.5 Relatório para o médico

PDF gerado no aparelho: período, medicamentos, adesão (%), doses perdidas, consultas, exames,
últimos check-ins de humor (sem texto do diário). Compartilhado por WhatsApp/e-mail/impressão
via folha nativa.

---

## 9. Comportamento Web (PC)

- Mesmas rotas e telas; layout responsivo com `breakpoint` em 900 px.
- Barra fixa: "Alertas de medicação só funcionam no celular".
- Login Google com Client ID **Web** e origem fixa `http://localhost:8080`.
- Banco em IndexedDB/OPFS via drift WASM — requer `sqlite3.wasm`, `drift_worker.js` e o
  `*.dart.js` gerado, servidos junto com o build.
- Sem alarmes, sem câmera (usa seletor de arquivo), sem share sheet (download do PDF).
- Serve como segunda tela e como ambiente de teste rápido, não como requisito.

---

## 10. Saúde mental — regras do POC

Sem LLM no núcleo da decisão. Regra local, determinística e explicável:

| Sinal | Peso |
|---|---|
| Check-in ausente por ≥ 3 dias | 2 |
| Humor médio (7 d) cai ≥ 1 ponto vs. 30 d | 2 |
| Energia média (7 d) ≤ 2 | 1 |
| Adesão a medicamento cai > 30% na semana | 1 |
| Nenhuma saída/atividade registrada em 7 d | 1 |

- Soma ≥ 3 → sugere atividade leve e pergunta "quer conversar?".
- Soma ≥ 5 por 2 semanas → oferece **avisar contato de confiança** (nunca automático).
- Toda sugestão é opção, não ordem. Nada de "você está deprimido" — o app sinaliza padrão, não diagnostica.
- O texto do diário **nunca** é lido por essas regras.

---

## 11. Compartilhamento (fora do POC, desenhado agora)

O modelo já nasce preparado, sem implementar:

- Campo `visibility` em toda entidade desde a primeira migração.
- Função pura `buildSharedProjection()` com **allowlist**:

| Entra | Nunca entra |
|---|---|
| Próximas doses e adesão (7 d) | Diário |
| Consultas e exames agendados | Texto de check-in |
| Alerta "não tomou a dose das 8h" | Resultados completos de exame |
| Humor agregado (sem texto) | Receitas e documentos |

Fase 1: espelho somente-leitura em `shared/summary.json` numa pasta **normal** do Drive,
compartilhada com a conta da outra pessoa. Fase 2 (se ela precisar agir): backend com auth e RLS.

---

## 12. Telas do MVP (todas no Android)

| # | Tela | Conteúdo |
|---|---|---|
| 1 | **Onboarding** | LGPD, login, permissões, primeiro medicamento |
| 2 | **Hoje** | Próxima dose (grande) + Tomei; doses do dia; tarefas; próximos 7 dias; botão Conversar |
| 3 | **Medicamentos** | Lista, ficha, novo/editar, receita por foto, histórico de adesão |
| 4 | **Saúde** | Agenda de consultas/exames, resultado com anexo, recomendações, exercícios |
| 5 | **Mente** | Check-in (2 toques), diário, tendência 30 d, sugestões |
| 6 | **Diário** | Lista e editor, acesso com PIN/biometria |
| 7 | **Tarefas** | Hoje, 7 dias, destaque 30 dias, categorias, recorrência |
| 8 | **Conversa** | Threads daily/weekly, resumo semanal e mensal |
| 9 | **Ajustes** | Conta/sync, privacidade, exportar, modo simples, acessibilidade |

Fora do MVP: widget de tela inicial, voz, iOS, wearable, push para terceiros.

---

## 13. Acessibilidade e "modo simples"

- Fonte base 18 sp; escala até 200% sem quebrar layout.
- Contraste mínimo 4.5:1; alvos de toque ≥ 48 dp.
- **Modo simples:** esconde tudo menos "próxima dose", "tomei" e "como você está?". Ativável em
  Ajustes e no onboarding.
- Textos sem jargão: "remédio", não "adesão terapêutica".
- Toda ação destrutiva pede confirmação em linguagem clara.

---

## 14. Segurança e LGPD

- Dado de saúde é dado sensível: consentimento explícito no onboarding, revogável.
- Tokens só em `SecureStore` (Android). No Web, em memória + `localStorage` — risco aceito no POC.
- Banco local sem cifra no POC; cifra SQLCipher na fase 2, com migração planejada.
- Diário com `local_only = 1` por padrão: não sobe para o Drive.
- Exportação e exclusão de todos os dados disponíveis em Ajustes.
- Nenhum dado vai para terceiros. Sem analytics no POC.

---

## 15. Critérios de aceite do POC

1. Celular bloqueado por 8 h: alarme dispara dentro de 60 s do horário.
2. Confirmar dose pela tela de bloqueio, sem abrir o app.
3. Modo avião por 24 h: tudo funciona, sync recupera ao voltar.
4. Reiniciar o aparelho: alarmes reagendados corretamente.
5. Instalar atualização do APK: alarmes preservados.
6. Android + Web convergem para o mesmo estado após edições alternadas.
7. Todo cadastro feito exclusivamente no celular, sem tocar no PC.
8. PDF do relatório gerado e compartilhado pelo celular.
9. Diário nunca aparece em nenhuma exportação.

---

## 16. Fases

| Fase | Entrega |
|---|---|
| **F0** | Esqueleto Flutter, drift, tema, navegação, CI de build APK |
| **F1** | Medicação: cadastro, esquema, alarme, Tomei, histórico |
| **F2** | Sync Drive (log + merge) nos dois alvos |
| **F3** | Hoje + tarefas |
| **F4** | Saúde: consultas, exames, anexos, recomendações, exercícios |
| **F5** | Mente: check-in, diário, tendência, regras de sinal |
| **F6** | Conversa diária/semanal e resumos |
| **F7** | Relatório PDF e exportação |

---

## 17. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| Fabricante mata o app e perde alarme | Crítico | Pedir isenção de bateria; teste de 8 h por fabricante; alarme redundante |
| Drift WASM mal configurado no Web | Médio | Empacotar os 3 assets no build; teste automatizado de abertura |
| Dois Client IDs OAuth divergentes | Médio | Keystore de release fixo desde o início; documentar SHA-1 |
| Refresh token expira em 7 dias (Testing) | Baixo | Re-login rápido; Android renova no uso diário |
| Escopo crescer além do POC | Alto | Fases fechadas; nada de backend antes de F7 |

---

## 18. Decisões abertas

1. LLM na conversa: local, API externa, ou nenhum no POC? (sugestão: nenhum no POC; roteiro
   pré-escrito com slots preenchidos pelo contexto — valida o formato antes de gastar com IA)
2. Diário: `local_only` sempre, ou sincroniza entre seus próprios aparelhos? (sugestão: sincroniza
   no seu Drive, nunca na projeção)
3. Ícone/nome do produto.
