# Gerenciador de Deploy FTPS (Terminal)

Gerenciador de deploy FTPS multi-instância via terminal, inspirado no fluxo de "Keep remote directory up to date", com sincronização manual controlada.

## Objetivo

Este projeto permite:
- monitorar alterações locais por instância (`create`, `modify`, `delete`, `move`)
- registrar pendências sem enviar automaticamente
- sincronizar manualmente com `sync`
- operar múltiplos projetos/instâncias
- auditar diretório remoto antes do deploy

## Requisitos

Dependências obrigatórias:
- `bash`
- `lftp`
- `inotify-tools` (fornece `inotifywait`)

Instalação (Ubuntu/Debian):

```bash
sudo apt-get update
sudo apt-get install -y lftp inotify-tools
```

## Estrutura

```text
gerenciador_deploy_projetos/
├── ftpctl
├── bin/
│   ├── common.sh
│   ├── watch_instance.sh
│   └── sync_instance.sh
├── instances/
├── state/
├── logs/
└── tmp/
```

## Setup Inicial

1. Entre no diretório do projeto:

```bash
cd /home/alves/genesis/projects/ftp/gerenciador_deploy_projetos
```

2. Crie/ajuste a instância:

```bash
./ftpctl create brold_burguer
```

3. Crie sua configuracao a partir do exemplo versionado:

```bash
cp instances/instance.example.conf instances/<instancia>.conf
```

4. Edite `instances/<instancia>.conf` com valores reais:
- `LOCAL_DIR`
- `REMOTE_DIR`
- `FTP_HOST`
- `FTP_USER`
- `FTP_PASS`
- `FTP_SSL`
- `FTP_VERIFY_CERT`
- `EXCLUDES`

5. Proteja credenciais:

```bash
chmod 600 instances/*.conf
```

## Comandos Principais

```bash
./ftpctl list
./ftpctl create <instancia>
./ftpctl use <instancia>
./ftpctl current
./ftpctl watch [instancia]
./ftpctl stop [instancia]
./ftpctl status [instancia]
./ftpctl pending [instancia]
./ftpctl sync [instancia] [--delete]
./ftpctl remote-ls [instancia] [diretorio]
```

Referência completa: `DOCUMENTACAO_COMANDOS.md`.

## Fluxo Recomendado

```bash
./ftpctl use brold_burguer
./ftpctl watch

# editar arquivos no projeto local

./ftpctl pending
./ftpctl remote-ls
./ftpctl sync
```

Com remoção remota:

```bash
./ftpctl sync --delete
```

## Auditoria de Destino Remoto

Antes de sincronizar, confira o destino com:

```bash
./ftpctl remote-ls
```

Isso mostra:
- instância ativa
- host
- diretório remoto auditado
- `pwd` remoto
- listagem `cls -la`

## Execução Global (sem `./`)

Para usar `ftpctl` de qualquer pasta:

```bash
sudo ln -sf /home/alves/genesis/projects/ftp/gerenciador_deploy_projetos/ftpctl /usr/local/bin/ftpctl
hash -r
```

## Troubleshooting

Se `watch` falhar:
1. Verifique o log:

```bash
tail -n 100 logs/<instancia>.watch.log
```

2. Confirme dependências:

```bash
command -v inotifywait
command -v lftp
```

3. Confirme `LOCAL_DIR` existente no `.conf`.

Se houver linha antiga de warning no pending (ex.: fallback polling), limpe:

```bash
: > state/<instancia>.pending
```

## Segurança e Boas Práticas

- Não commitar credenciais reais (`FTP_PASS`) em repositório público.
- Preferir variáveis/segredos no ambiente quando possível.
- Manter `instances/*.conf` com permissão `600`.
- Validar destino com `remote-ls` antes de `sync`.

## Checklist Pré-Push Git

Antes de subir para o git:
1. Verifique se não há senha real em `instances/*.conf`.
2. Garanta que logs e estado não contêm dados sensíveis.
3. Revise alterações com `git diff`.
4. Rode testes básicos de comando (`list`, `current`, `status`).

## Licença

Defina a licença do projeto conforme sua necessidade (MIT, Apache-2.0, etc.).
