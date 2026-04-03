# Gerenciador Deploy Projetos - Comandos

Este documento lista os comandos disponíveis no `ftpctl` e o significado de cada um.

## Visão geral

Comando principal:

```bash
./ftpctl <comando> [opcoes]
```

## Comandos

### `./ftpctl list`
Lista todas as instâncias disponíveis em `instances/*.conf`.
Também marca qual está ativa no momento.

### `./ftpctl create <instancia>`
Cria um novo arquivo de configuração de instância em `instances/<instancia>.conf`.
Inclui template padrão com campos de FTPS e exclusões.

Regras:
- Não sobrescreve instância existente.
- Aceita nomes com letras, números, `_` e `-`.
- Aplica permissão `chmod 600` no arquivo criado.

### `./ftpctl use <instancia>`
Define a instância ativa.
A instância ativa é salva em `state/current_instance`.

### `./ftpctl current`
Mostra a instância ativa atual.

### `./ftpctl watch [instancia]`
Inicia o watcher em background para monitorar alterações locais da instância.

Se `instancia` não for informada, usa a instância ativa.

O watcher:
- Monitora `LOCAL_DIR` com `inotifywait`.
- Registra eventos em `state/<instancia>.pending`.
- Salva PID em `state/<instancia>.watch.pid`.
- Loga saída em `logs/<instancia>.watch.log`.

### `./ftpctl stop [instancia]`
Para o watcher da instância.

Se `instancia` não for informada, usa a instância ativa.

### `./ftpctl status [instancia]`
Mostra status do watcher da instância:
- `RUNNING` com PID quando ativo
- `STOPPED` quando parado

Se `instancia` não for informada, usa a instância ativa.

### `./ftpctl pending [instancia]`
Exibe alterações pendentes registradas pelo watcher.

Arquivo usado:
- `state/<instancia>.pending`

Se `instancia` não for informada, usa a instância ativa.

### `./ftpctl sync [instancia] [--verify] [--verify-pending]`
Executa sincronização incremental manual via FTPS, baseada no arquivo de pendências (`state/<instancia>.pending`).

Se `instancia` não for informada, usa a instância ativa.

Comportamento:
- Envia apenas arquivos alterados/criados.
- Remove remoto para itens marcados como `DELETE` no pending.
- Ao final, exibe resumo com `APPLIED` (confirmado pelo output do lftp) e `PLANNED` (planejado a partir do pending).
- Usa SSL/FTPS conforme configuração da instância.
- Usa lock de sync em `state/<instancia>.sync.lock` para evitar concorrência.
- Log em `logs/<instancia>.sync.log` é opcional (desligado por padrão).
- Para ativar, configure `SYNC_LOG_ENABLED="true"` (ou `ENABLE_LOGS="true"`) no arquivo da instância.
- Limpa pendências (`state/<instancia>.pending`) após sucesso.
- Com `--verify`, valida no remoto os paths alterados e imprime `VERIFY_OK`/`VERIFY_FAIL`.
- Com `--verify-pending`, valida o que esta pendente no remoto sem fazer upload.

### `./ftpctl sync-all [instancia] [--delete] [--verify]`
Executa sincronização completa via `mirror -R` (espelhamento total).

Se `instancia` não for informada, usa a instância ativa.

Comportamento:
- Respeita `EXCLUDES` da instância.
- Usa SSL/FTPS conforme configuração.
- Pode ignorar validação de certificado (`FTP_VERIFY_CERT="false"`).
- Usa lock de sync em `state/<instancia>.sync.lock` para evitar concorrência.
- Log em `logs/<instancia>.sync.log` é opcional (desligado por padrão).
- Para ativar, configure `SYNC_LOG_ENABLED="true"` (ou `ENABLE_LOGS="true"`) no arquivo da instância.
- Limpa pendências (`state/<instancia>.pending`) após sucesso.
- Com `--verify`, valida no remoto os paths alterados e imprime `VERIFY_OK`/`VERIFY_FAIL`.
- Com `--verify-pending`, valida o que esta pendente no remoto sem fazer upload.

Flag opcional:
- `--delete`: remove no remoto arquivos que não existem localmente.

## Fluxo recomendado

```bash
cd /home/alves/genesis/projects/ftp/gerenciador_deploy_projetos

./ftpctl list
./ftpctl use brold_burguer
./ftpctl watch

# editar arquivos locais

./ftpctl pending
./ftpctl sync
```

Para espelhamento completo:

```bash
./ftpctl sync-all
./ftpctl sync-all --delete
```

## Dependências

- `bash`
- `lftp`
- `inotifywait` (pacote `inotify-tools`)

## Segurança

Os arquivos de instância contêm credenciais.
Recomendado:

```bash
chmod 600 instances/*.conf
```

### `./ftpctl remote-ls [instancia] [diretorio]`
Lista o diretório remoto via FTPS para auditoria antes do deploy.

Comportamento:
- Se `instancia` não for informada, usa a instância ativa.
- Se `diretorio` não for informado, usa `REMOTE_DIR` da configuração.
- Mostra cabeçalho com instância, host e diretório alvo.
- Executa `pwd` remoto e `cls -la` no diretório solicitado.

Exemplos:

```bash
./ftpctl remote-ls
./ftpctl remote-ls brold_burguer
./ftpctl remote-ls brold_burguer /frota
```

### `./ftpctl remote-diff [instancia] [--both|--to-local|--to-remote]`
Mostra diferenças em modo dry-run entre local e remoto.

Padrao: mostra apenas `REMOTO -> LOCAL` (seguro para auditoria sem risco de confundir com deploy).

Opcoes:
- `--to-local`: somente remoto para local (padrao)
- `--to-remote`: somente local para remoto
- `--both`: mostra os dois lados

As exclusoes da instancia (`EXCLUDES`) sao aplicadas no dry-run.

Não altera arquivos em nenhum lado.

### `./ftpctl pull [instancia] <arquivo_remoto> [destino_local] [-y|--yes]`
Baixa um arquivo remoto para o ambiente local.

Comportamento:
- Se `instancia` não for informada, usa a instância ativa.
- Se `destino_local` nao for informado, salva em `LOCAL_DIR` preservando a arvore relativa a `REMOTE_DIR`.
- Se o arquivo já existir localmente, pede confirmação.
- Com `-y`/`--yes`, sobrescreve sem perguntar.

Exemplos:

```bash
./ftpctl pull /frota/logs/error.log
# Salva em: LOCAL_DIR/frota/logs/error.log (quando REMOTE_DIR=/)
./ftpctl pull brold_burguer /frota/logs/error.log
./ftpctl pull brold_burguer /frota/logs/error.log /tmp -y
```

Atualizacao `remote-diff`:
- Agora lista apenas caminhos essenciais (FILE/DIR/DEL), sem verbosidade do lftp.
- Por padrao, mostra `REMOTO -> LOCAL`.
- Ao final pergunta se deseja baixar as diferencas.
- Use `--apply` (ou `-y`) para aplicar sem perguntar.

### `./ftpctl remote-recent [instancia]`
Lista somente arquivos remotos alterados/criados na última 1 hora.

Características:
- Não baixa arquivos.
- Não altera nada no local.
- Exibe saída enxuta (apenas caminhos).
- Respeita `EXCLUDES` da instância.

Exemplo:

```bash
./ftpctl remote-recent
./ftpctl remote-recent brold_burguer
```
