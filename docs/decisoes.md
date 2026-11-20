# Decisões de arquitetura

Registro curto do porquê de cada desvio em relação à
[especificação técnica](especificacao-tecnica.md).

---

## ADR-001 — Armazenamento em sembast, não em SQLite/drift

**Data:** 2026-11-15
**Status:** aceita

### Contexto

A especificação previa `drift` sobre SQLite. O alvo duplo (Android nativo + Web)
é o motivo de o drift ser atraente: mesma camada de acesso nos dois lados.

### Problema

O drift na Web exige `sqlite3.wasm`, `drift_worker.js` e o artefato de codegen
servidos junto, além de `build_runner` no ciclo de build. É configuração que
quebra com frequência e cujo diagnóstico é lento — justamente o que um POC de
uma pessoa não pode gastar.

O volume de dados também não justifica SQL: um usuário, algumas dezenas de
registros por mês, consultas triviais.

### Decisão

Usar **sembast** — banco de documentos sobre arquivo JSON no Android e
IndexedDB na Web. Mesma API nos dois alvos, sem codegen, sem assets extras.

### Consequências

- **Positivas:** build simples, um único modelo mental, testes rodam em memória.
- **Negativas:** sem consultas SQL; agregações são feitas em Dart. Para o volume
  do POC isso é irrelevante, mas não escala para dezenas de milhares de eventos
  sem paginação.
- **Migração futura:** o modelo lógico (§5 da especificação) não muda. Trocar o
  sembast por drift é substituir a camada `AppStore`, mantendo os mesmos
  métodos. O `change_log` é independente do motor de banco.

---

## ADR-002 — Sem biblioteca de gerenciamento de estado

**Data:** 2026-11-15
**Status:** aceita

`ChangeNotifier` + `InheritedNotifier` em vez de Riverpod/Bloc. O app tem cinco
telas e um único fluxo de dados. Cada dependência a menos é uma chance a menos
de conflito de versão no build.

Se o app crescer para conversa com IA, sync em tempo real e múltiplos
observadores, a troca por Riverpod é local: só o `AppController` e o
`AppScope` mudam.

---

## ADR-003 — Sem LLM na conversa (nesta versão)

**Data:** 2026-11-15
**Status:** aceita

A conversa diária será implementada como **roteiro determinístico com slots**
preenchidos pelo contexto do dia (doses, compromissos, tarefas, humor). Isso
valida o formato e a frequência antes de introduzir custo, latência e
imprevisibilidade de modelo.

---

## ADR-004 — Alarmes só no Android

**Data:** 2026-11-15
**Status:** aceita

Na Web não existe alarme confiável com a janela fechada. O agendador é um no-op
que reporta `isSupported = false`, e a interface avisa em vez de falhar em
silêncio. Alarme é responsabilidade do celular.
