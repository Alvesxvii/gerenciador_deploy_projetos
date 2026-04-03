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
